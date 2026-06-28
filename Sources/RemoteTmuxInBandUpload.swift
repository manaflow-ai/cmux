import Foundation

/// Builds and parses the commands for uploading a file to a remote tmux host
/// *in band* — over the existing `tmux -CC` control connection, with no second
/// SSH session/channel (so it works on `MaxSessions 1` hosts) and no remote
/// helper binary.
///
/// The file is base64-encoded locally, streamed to a remote temp file as a series
/// of `run-shell "printf %s <chunk> >> <file>"` commands, then decoded + verified
/// remotely. `run-shell` stdout is NOT readable over control mode, so the result
/// (size + checksum) is reported back through a tmux user option that cmux reads
/// with `show-options`.
///
/// Quoting: each command is sent as a tmux double-quoted `run-shell` argument.
/// Inside tmux `"..."` only `"`, `\`, and `#` are special (the rest — including
/// `;`, `$`, `()`, `<`, `>`, `&&`, `||`, single quotes — pass through to the
/// shell). The standard base64 alphabet (`[A-Za-z0-9+/=]`) and the generated
/// remote paths contain none of those, and the finalize command is written
/// without any `"`/`\`/`#`, so no escaping layer is required. All helpers are
/// `nonisolated` and pure for unit testing.
enum RemoteTmuxInBandUpload {
    /// Max upload size; larger files are rejected rather than streamed chunk by
    /// chunk over the control connection.
    static let maxFileBytes = 25 * 1024 * 1024

    /// Base64 text per `printf` append. 32 KiB stays well under the control
    /// connection's 256 KiB pending-stdin cap and under per-argument argv limits.
    static let chunkSize = 32 * 1024

    /// Remote temp directory for one upload (`mkdir`, not `-p`, so a collision
    /// fails instead of reusing an attacker-prepared path).
    static func tempDir(id: String) -> String { "/tmp/cmux-ul-\(id)" }

    /// Final remote path the user references (kept after success), matching the
    /// `/tmp/cmux-drop-*` shape of the scp path.
    static func outputPath(id: String, sanitizedExtension ext: String?) -> String {
        if let ext, !ext.isEmpty { return "/tmp/cmux-drop-\(id).\(ext)" }
        return "/tmp/cmux-drop-\(id)"
    }

    /// The tmux user option the remote finalize writes its result into.
    static func ackOption(id: String) -> String { "@cmux_ul_\(id)" }

    /// A collision-resistant id with only `[a-f0-9]` (safe everywhere).
    static func makeID(_ uuid: UUID) -> String {
        uuid.uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    }

    /// Sanitizes a file extension to `[A-Za-z0-9]{1,16}`, returning nil when the
    /// original has any other character (so it can't inject shell/tmux syntax via
    /// the remote path). The leading dot is not included.
    static func sanitizedExtension(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw.count <= 16 else { return nil }
        let ok = raw.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return ok ? raw : nil
    }

    /// Splits already-encoded base64 TEXT into command-sized chunks. Splitting the
    /// encoded string (not the raw bytes) keeps decoding correct — re-encoding raw
    /// sub-ranges independently could introduce interior padding.
    static func base64Chunks(_ base64: String, size: Int = chunkSize) -> [String] {
        guard size > 0, !base64.isEmpty else { return base64.isEmpty ? [] : [base64] }
        var chunks: [String] = []
        var index = base64.startIndex
        while index < base64.endIndex {
            let end = base64.index(index, offsetBy: size, limitedBy: base64.endIndex) ?? base64.endIndex
            chunks.append(String(base64[index..<end]))
            index = end
        }
        return chunks
    }

    // MARK: - Command builders (the string passed as run-shell's argument)

    static func setupShellCommand(id: String) -> String {
        let dir = tempDir(id: id)
        return "umask 077 && mkdir \(dir) && : > \(dir)/f.b64"
    }

    static func appendShellCommand(id: String, chunk: String) -> String {
        "printf %s \(chunk) >> \(tempDir(id: id))/f.b64"
    }

    /// Decode → verify size+cksum → atomic move → report result via tmux option →
    /// always clean up the temp dir. Uses only shell tokens that survive tmux
    /// double-quoting (no `"`, `\`, or `#`). The tmux binary is resolved via a
    /// `command -v` fallback chain because `run-shell`'s PATH is not guaranteed to
    /// include it.
    static func finalizeShellCommand(id: String, sanitizedExtension ext: String?) -> String {
        let dir = tempDir(id: id)
        let out = outputPath(id: id, sanitizedExtension: ext)
        let opt = ackOption(id: id)
        let decode =
            "( base64 -d <\(dir)/f.b64 >\(dir)/o 2>/dev/null"
            + " || base64 -D <\(dir)/f.b64 >\(dir)/o 2>/dev/null"
            + " || openssl base64 -d -A <\(dir)/f.b64 >\(dir)/o 2>/dev/null )"
        let verify =
            "set -- $(wc -c <\(dir)/o) && sz=$1 && set -- $(cksum <\(dir)/o) && ck=$1"
        let tmuxResolve =
            "T=$(command -v tmux 2>/dev/null"
            + " || command -v $HOME/.local/bin/tmux 2>/dev/null"
            + " || command -v /opt/homebrew/bin/tmux 2>/dev/null"
            + " || command -v /usr/local/bin/tmux 2>/dev/null"
            + " || command -v /usr/bin/tmux 2>/dev/null"
            + " || echo tmux)"
        return
            "d=\(dir); "
            + "\(decode) && \(verify) && mv -f \(dir)/o \(out) && R=OK:$sz:$ck || R=ERR; "
            + "\(tmuxResolve); $T set -g \(opt) $R; rm -rf $d"
    }

    // MARK: - Result parsing

    struct Ack: Equatable {
        let size: Int
        let cksum: UInt32
    }

    /// Parses the `OK:<size>:<cksum>` ack from `show-options -gv`. Returns nil for
    /// `ERR`, an empty/missing option, or any malformed value.
    static func parseAck(_ lines: [String]?) -> Ack? {
        guard let raw = lines?.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.hasPrefix("OK:") else { return nil }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, let size = Int(parts[1]), let cksum = UInt32(parts[2]) else { return nil }
        return Ack(size: size, cksum: cksum)
    }

    // MARK: - Local POSIX cksum (CRC-32, must match `cksum(1)`)

    private static let crcTable: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for index in 0..<256 {
            var crc = UInt32(index) << 24
            for _ in 0..<8 {
                crc = (crc & 0x8000_0000) != 0 ? (crc << 1) ^ 0x04C1_1DB7 : (crc << 1)
            }
            table[index] = crc
        }
        return table
    }()

    /// The POSIX `cksum` CRC of `data` (data bytes followed by the length octets,
    /// low byte first, then one's complement), used to verify the remote decode.
    static func posixCksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0
        for byte in data {
            crc = (crc << 8) ^ crcTable[Int(((crc >> 24) ^ UInt32(byte)) & 0xff)]
        }
        var length = data.count
        while length != 0 {
            crc = (crc << 8) ^ crcTable[Int(((crc >> 24) ^ UInt32(length & 0xff)) & 0xff)]
            length >>= 8
        }
        return ~crc
    }
}
