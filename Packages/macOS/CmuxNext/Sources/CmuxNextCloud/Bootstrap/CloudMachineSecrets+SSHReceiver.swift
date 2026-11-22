import CryptoKit
public import Foundation

/// The terminal receiver: how `cmux cloud deliver-secrets` reaches an own SSH machine or an acpmux peer
/// (SSHMachineSecrets, CloudHandlers+OwnMachineSecrets), which have no carrier. Cloud machines never use it:
/// their values are sealed to the machine's daemon (`secrets-v1`, ``CloudMachineSecrets``).
///
/// A value travels only over the ssh session, typed into a short-lived terminal that runs ``receiver``
/// with echo off: never through an argv or a log. Only the receiver, which holds no secret, and its ticket
/// (``ticket(nonce:key:names:)``: a one-time nonce, a payload key and the names, no value) are installed
/// first; the receiver reads and removes the ticket before anything else. It prints ``ready`` and the nonce
/// once echo is off, reads base64 lines up to ``end``, writes the file and answers ``ok`` or ``error`` with a
/// fixed code.
extension CloudMachineSecrets {
    public static let receiverPath = CloudMachineConfig.directory + "/receive-secrets"
    /// The receiver's ticket, in the work user's 0700 folder beside it.
    public static let ticketPath = CloudMachineConfig.directory + "/receive-secrets.ticket"
    public static let ready = "CMUX-SECRETS-READY"
    public static let end = "CMUX-SECRETS-END"
    public static let ok = "CMUX-SECRETS-OK"
    public static let error = "CMUX-SECRETS-ERR"
    /// How long the receiver waits for the whole payload before it gives up (and the Mac waits for each answer).
    public static let waitSeconds = 60

    /// The bytes typed into the receiver: base64 of `NAME=value` lines, 76 columns a line, then
    /// ``mac`` with the SHA-256 of `key`, a line feed and those lines, then ``end`` and `key`. `key`
    /// reaches the receiver only in its ticket and is never printed, so text another client types
    /// into the terminal (it sees the screen, never the ticket) can only make the delivery fail:
    /// the receiver keeps the old set unless both match. A value is one line (`cmux cloud secret set`
    /// refuses line breaks).
    public static func payload(_ values: [(name: String, value: String)], key: String) -> Data {
        let body = values.map { "\($0.name)=\($0.value)\n" }.joined()
        var encoded = Data(body.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
        if !encoded.isEmpty { encoded += "\n" }
        let digest = SHA256.hash(data: Data((key + "\n" + encoded).utf8)).map { String(format: "%02x", $0) }.joined()
        return Data((encoded + "\(mac) \(digest)\n\(end) \(key)\n").utf8)
    }

    public static let mac = "CMUX-SECRETS-MAC"

    /// The receiver's ticket: the nonce, the payload key and the names it may write (space-separated),
    /// a line each. No value.
    public static func ticket(nonce: String, key: String, names: [String]) -> Data {
        Data("\(nonce)\n\(key)\n\(names.joined(separator: " "))\n".utf8)
    }

    /// The calls a delivery makes (the ticket over the file API, the rest over the machine's daemon
    /// link), so a test records them.
    public struct Link: Sendable {
        /// Writes the receiver's ticket (``ticketPath``).
        public var writeTicket: @Sendable (_ ticket: Data) async throws -> Void
        /// Starts `argv` in a new terminal; answers its handle.
        public var start: @Sendable (_ argv: [String]) async throws -> String
        /// Waits until the terminal's screen matches `pattern` (a regex); answers the screen text.
        public var waitFor: @Sendable (_ terminal: String, _ pattern: String, _ seconds: Int) async throws -> String
        /// Types `bytes` into the terminal.
        public var type: @Sendable (_ terminal: String, _ bytes: Data) async throws -> Void
        public var close: @Sendable (_ terminal: String) async -> Void

        public init(writeTicket: @escaping @Sendable (Data) async throws -> Void,
                    start: @escaping @Sendable ([String]) async throws -> String,
                    waitFor: @escaping @Sendable (String, String, Int) async throws -> String,
                    type: @escaping @Sendable (String, Data) async throws -> Void,
                    close: @escaping @Sendable (String) async -> Void) {
            self.writeTicket = writeTicket
            self.start = start
            self.waitFor = waitFor
            self.type = type
            self.close = close
        }
    }

    public struct DeliveryFailed: Error, Equatable {
        public var reason: String

        public init(reason: String) { self.reason = reason }
    }

    /// The receiver's error codes; any other answer is reported as `unexpected`, so nothing a
    /// machine prints (possibly a value) reaches an error.
    static let errorCodes: Set<String> = ["no-tty", "mkdir", "mktemp", "eof", "bad-base64", "bad-name", "bad-line", "duplicate", "write", "interrupted", "nonce", "bad-mac"]

    /// Runs the receiver in a new terminal, types the payload once it says echo is off, and closes
    /// the terminal. Answers how many names the machine wrote. `receiverAt` and `ticketAt` are where the
    /// link put them (an own machine's are under its own home, `SSHMachineSecrets`).
    public static func deliver(_ values: [(name: String, value: String)], over link: Link,
                               nonce: String = randomHex(), key: String = randomHex(),
                               receiverAt: String = receiverPath, ticketAt: String = ticketPath) async throws -> Int {
        // A set of any size: nothing here or in the receiver refuses it for its size.
        let typed = payload(values, key: key)
        // The names travel with the key: the receiver writes these and nothing else.
        try await link.writeTicket(ticket(nonce: nonce, key: key, names: values.map(\.name)))
        let terminal = try await link.start(["sh", receiverAt, ticketAt])
        let outcome: Result<String, any Error>
        do {
            let opened = try await link.waitFor(terminal, "\(ready) \(nonce)|\(error) [a-z-]+", waitSeconds)
            // The go-ahead must be the receiver's last word: an error after it means it already gave up.
            guard answer(opened, ready: true) == "\(ready) \(nonce)" else { throw DeliveryFailed(reason: code(opened)) }
            try await link.type(terminal, typed)
            // The answer carries a token only the receiver can make (it needs the key): an OK another
            // client typed onto the screen earlier never matches.
            outcome = .success(try await link.waitFor(terminal, "\(ok) \(values.count) \(okToken(key: key, count: values.count))|\(error) [a-z-]+", waitSeconds))
        } catch {
            outcome = .failure(error)
        }
        // Closed on every path, once: the receiver has ended, or is ended with its terminal.
        await link.close(terminal)
        let done = try outcome.get()
        guard answer(done) == "\(ok) \(values.count) \(okToken(key: key, count: values.count))" else { throw DeliveryFailed(reason: code(done)) }
        return values.count
    }

    /// The receiver's proof of success: the first 128 bits (32 hex digits) of SHA-256 of the key,
    /// `\nok ` and the count it wrote, so its whole line fits a narrow (60-column) terminal unwrapped.
    static func okToken(key: String, count: Int) -> String {
        String(SHA256.hash(data: Data("\(key)\nok \(count)".utf8)).map { String(format: "%02x", $0) }.joined().prefix(32))
    }

    /// The receiver's terminal: wide enough that no marker line wraps, whatever the person's panes are.
    public static let terminalColumns = 120

    /// 32 random hex digits (128 bits).
    public static func randomHex() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }

    /// The receiver's error code on `screen`, or `unexpected`.
    static func code(_ screen: String) -> String {
        guard let line = answer(screen), line.hasPrefix(error + " ") else { return "unexpected" }
        let code = String(line.dropFirst(error.count + 1))
        return errorCodes.contains(code) ? code : "unexpected"
    }

    /// The receiver's last answer line on `screen`.
    static func answer(_ screen: String, ready includeReady: Bool = false) -> String? {
        screen.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix(ok) || $0.hasPrefix(error) || (includeReady && $0.hasPrefix(ready)) }
    }

    /// The receiver (`~/.cmux/machine-config/receive-secrets`, run with `sh`). It replaces the whole
    /// file, so a removed or renamed secret goes too; the payload stays in a 0700 temporary folder
    /// that is removed on every exit. It needs nothing but sh, stty, base64, mktemp and sha256sum or shasum.
    public static let receiver = #"""
        #!/bin/sh
        # cmux secret receiver, written by the cmux app (cmux cloud deliver-secrets). Values arrive
        # typed over the app's daemon link with echo off; they never reach the screen, argv or a log.
        set -u
        umask 077
        # The ticket (the app's nonce, its payload key and the names it sends, never a value) is read and
        # removed first: no environment, argv, screen or terminal receipt holds them.
        ticket=${1:-} nonce= mackey= names=
        if [ -n "$ticket" ] && [ -f "$ticket" ] && [ ! -L "$ticket" ]; then
          { IFS= read -r nonce && IFS= read -r mackey && IFS= read -r names; } < "$ticket" || nonce=
        fi
        [ -n "$ticket" ] && rm -f "$ticket"
        out="$HOME/.config/cmux/machine-secrets.env"
        mkdir -p "${out%/*}" && chmod 700 "${out%/*}" || { echo "CMUX-SECRETS-ERR mkdir"; exit 1; }
        # Beside the file, so the final rename is atomic and nothing lands in a shared /tmp.
        tmp=$(mktemp -d "${out%/*}/.secrets.XXXXXX") || { echo "CMUX-SECRETS-ERR mktemp"; exit 1; }
        # A sender that never finishes (the Mac went away) does not keep this receiver or its terminal.
        # It holds no terminal, and its sleep ends with it.
        ( sleep 120 & s=$!; trap 'kill "$s" 2>/dev/null; exit 0' TERM; wait "$s" && kill -TERM $$ 2>/dev/null ) </dev/null >/dev/null 2>&1 &
        watchdog=$!
        # Echo stays off on every exit: the terminal is closed after, and a payload typed into it after
        # an early exit (another client sent EOF) never shows.
        cleanup() { kill "$watchdog" 2>/dev/null; rm -rf "$tmp"; }
        trap cleanup EXIT
        trap 'echo "CMUX-SECRETS-ERR interrupted"; exit 1' INT HUP TERM
        stty -echo 2>/dev/null || { echo "CMUX-SECRETS-ERR no-tty"; exit 1; }
        # SHA-256 and base64 decoding as Linux (coreutils) or macOS (shasum, base64 -D) spell them.
        digest() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; }
        unbase64() { if printf 'eA==' | base64 -d >/dev/null 2>&1; then base64 -d; else base64 -D; fi; }
        case "$nonce" in ''|*[!0-9A-Fa-f]*) echo "CMUX-SECRETS-ERR nonce"; exit 1 ;; esac
        case "$mackey" in ''|*[!0-9A-Fa-f]*) echo "CMUX-SECRETS-ERR nonce"; exit 1 ;; esac
        echo "CMUX-SECRETS-READY $nonce"
        : > "$tmp/b64"
        mac=""
        while IFS= read -r line; do
          [ "$line" = "CMUX-SECRETS-END $mackey" ] && break
          case "$line" in "CMUX-SECRETS-MAC "*) mac=${line#CMUX-SECRETS-MAC }; continue ;; esac
          printf '%s\n' "$line" >> "$tmp/b64" || { echo "CMUX-SECRETS-ERR write"; exit 1; }
        done
        [ "${line:-}" = "CMUX-SECRETS-END $mackey" ] || { echo "CMUX-SECRETS-ERR eof"; exit 1; }
        # Only what the app typed: the key never reached a screen, so nobody else could make this match.
        want=$({ printf '%s\n' "$mackey"; cat "$tmp/b64"; } | digest | cut -d' ' -f1)
        [ -n "$mac" ] && [ "$mac" = "$want" ] || { echo "CMUX-SECRETS-ERR bad-mac"; exit 1; }
        unbase64 < "$tmp/b64" > "$tmp/pairs" 2>/dev/null || { echo "CMUX-SECRETS-ERR bad-base64"; exit 1; }
        n=0
        : > "$tmp/env"
        while IFS= read -r pair || [ -n "$pair" ]; do
          key=${pair%%=*}
          value=${pair#*=}
          case "$key" in ''|[0-9]*|*[!A-Za-z0-9_]*) echo "CMUX-SECRETS-ERR bad-name"; exit 1 ;; esac
          [ "$key" = "$pair" ] && { echo "CMUX-SECRETS-ERR bad-line"; exit 1; }
          case " $names " in *" $key "*) ;; *) echo "CMUX-SECRETS-ERR bad-name"; exit 1 ;; esac
          grep -q "^export $key=" "$tmp/env" && { echo "CMUX-SECRETS-ERR duplicate"; exit 1; }
          quoted=$(printf '%s' "$value" | sed "s/'/'\\\\''/g") || { echo "CMUX-SECRETS-ERR write"; exit 1; }
          printf "export %s='%s'\n" "$key" "$quoted" >> "$tmp/env" || { echo "CMUX-SECRETS-ERR write"; exit 1; }
          n=$((n + 1))
        done < "$tmp/pairs"
        # Complete or nothing: the file that replaces the old set must hold every line it was sent.
        [ "$(grep -c '^export ' "$tmp/env")" -eq "$n" ] || { echo "CMUX-SECRETS-ERR write"; exit 1; }
        chmod 600 "$tmp/env" || { echo "CMUX-SECRETS-ERR write"; exit 1; }
        sync "$tmp/env" 2>/dev/null || true
        mv -f "$tmp/env" "$out" || { echo "CMUX-SECRETS-ERR write"; exit 1; }
        # Proof that this receiver, which holds the key, wrote the set: an OK typed by anyone else lacks it.
        tok=$(printf '%s\nok %s' "$mackey" "$n" | digest | cut -c1-32)
        echo "CMUX-SECRETS-OK $n $tok"
        """#
}
