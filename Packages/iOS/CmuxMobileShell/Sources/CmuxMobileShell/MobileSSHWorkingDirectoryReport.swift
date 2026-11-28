import Foundation

/// Reads the working directory a remote shell reports in its own output with
/// OSC 7 (`ESC ] 7 ; file://host/path BEL` or `ESC \`), the report fish
/// sends by default and zsh/bash send with terminal shell integration
/// (vte.sh, Apple Terminal's `/etc/zshrc_Apple_Terminal`, Ghostty, iTerm2).
/// Terminals, the Mac's Ghostty included, learn a shell's folder the same
/// way. Passive: nothing is sent to the shell, so a shell that never reports
/// leaves the directory unknown.
///
/// Fed the stream in arbitrary chunks; a report split across chunks is
/// joined. Other escape sequences and ordinary text pass through untouched
/// (this only observes; the bytes still go to the terminal).
struct MobileSSHWorkingDirectoryReport {
    /// Longest OSC body kept; a longer one is not a directory report.
    static let maximumReportLength = 4096

    private enum State {
        case ground
        case escape
        case osc
        case oscEscape
    }

    private var state: State = .ground
    private var body: [UInt8] = []
    private var overflowed = false

    /// The last directory reported so far, as an absolute remote path.
    private(set) var directory: String?

    /// Scans one chunk of output. Returns the newest directory reported in
    /// it, or `nil` when the chunk completed no report.
    @discardableResult
    mutating func consume(_ data: Data) -> String? {
        var reported: String?
        for byte in data {
            switch state {
            case .ground:
                if byte == 0x1B { state = .escape }
            case .escape:
                if byte == UInt8(ascii: "]") {
                    beginOSC()
                } else if byte != 0x1B {
                    state = .ground
                }
            case .osc:
                switch byte {
                case 0x07:
                    if let path = finishOSC() { reported = path }
                case 0x1B:
                    state = .oscEscape
                case 0x18, 0x1A:
                    // CAN / SUB abort a control string.
                    state = .ground
                default:
                    append(byte)
                }
            case .oscEscape:
                if byte == UInt8(ascii: "\\") {
                    if let path = finishOSC() { reported = path }
                } else if byte == UInt8(ascii: "]") {
                    // An unterminated OSC followed by a new one.
                    beginOSC()
                } else {
                    state = byte == 0x1B ? .escape : .ground
                }
            }
        }
        if let reported { directory = reported }
        return reported
    }

    private mutating func beginOSC() {
        state = .osc
        body.removeAll(keepingCapacity: true)
        overflowed = false
    }

    private mutating func append(_ byte: UInt8) {
        guard !overflowed else { return }
        if body.count >= Self.maximumReportLength {
            overflowed = true
            body.removeAll()
            return
        }
        body.append(byte)
    }

    private mutating func finishOSC() -> String? {
        state = .ground
        defer { body.removeAll(keepingCapacity: true) }
        guard !overflowed,
              body.count > 2,
              body[0] == UInt8(ascii: "7"),
              body[1] == UInt8(ascii: ";") else { return nil }
        return Self.path(fromReport: String(decoding: body.dropFirst(2), as: UTF8.self))
    }

    /// The absolute path in an OSC 7 payload: a `file://host/path` URL
    /// (percent-encoded, host ignored since it names the remote machine
    /// itself) or kitty's unencoded `kitty-shell-cwd://host/path`.
    static func path(fromReport report: String) -> String? {
        let schemes = [("file://", true), ("kitty-shell-cwd://", false)]
        guard let (prefix, percentEncoded) = schemes.first(where: {
            report.lowercased().hasPrefix($0.0)
        }) else { return nil }
        let afterScheme = report.dropFirst(prefix.count)
        // The host runs to the first "/", which starts the path.
        guard let slash = afterScheme.firstIndex(of: "/") else { return nil }
        let rawPath = String(afterScheme[slash...])
        let path = percentEncoded ? (rawPath.removingPercentEncoding ?? rawPath) : rawPath
        guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
        return path
    }
}
