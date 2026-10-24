// DEBUG and Demo builds only: never compiled into Production.
#if DEBUG
import Foundation

/// DEBUG: a Mac grid that is not the phone's, without a Mac
/// (`-CmuxMobileTerminalDemo -CmuxMobileHostGridDemo 120x40` for a shell
/// wider than the phone, `... 50x20,tui` for a full-screen app with fewer
/// rows). The screen must render the grid exactly: pan sideways, letterbox
/// below (PROTOCOL.md "Terminal sizing policy").
@MainActor
public final class TerminalHostGridDemoSession: TerminalSession {
    public let programName: String
    public private(set) var isAlternateScreen: Bool
    public let remoteColumns: Int?
    public let remoteRows: Int?
    private var handler: (@MainActor (TerminalSessionEvent) -> Void)?

    /// `spec`: `<cols>x<rows>` with an optional `,tui`.
    public init?(spec: String) {
        let parts = spec.split(separator: ",")
        let size = parts.first?.split(separator: "x").compactMap { Int($0) } ?? []
        guard size.count == 2, size[0] > 1, size[1] > 1 else { return nil }
        remoteColumns = size[0]
        remoteRows = size[1]
        isAlternateScreen = parts.dropFirst().contains("tui")
        programName = isAlternateScreen ? "htop" : "zsh"
    }

    public static var requestedSpec: String? {
        UserDefaults.standard.string(forKey: "CmuxMobileHostGridDemo")
    }

    public func start(_ handler: @escaping @MainActor (TerminalSessionEvent) -> Void) {
        self.handler = handler
        handler(.connection(.attached))
        let columns = remoteColumns ?? 80, rows = remoteRows ?? 24
        var text = "\u{1B}c"
        if isAlternateScreen {
            handler(.alternateScreen(true))
            text += "\u{1B}[?1049h\u{1B}[H\u{1B}[2J"
            let horizontal = String(repeating: "─", count: columns - 2)
            text += "\u{1B}[1;1H┌\(horizontal)┐"
            for row in 2..<rows { text += "\u{1B}[\(row);1H│\u{1B}[\(row);\(columns)H│" }
            text += "\u{1B}[\(rows);1H└\(horizontal)┘"
            let label = "Mac grid \(columns)×\(rows)"
            text += "\u{1B}[\(rows / 2);\(max(2, (columns - label.count) / 2))H\(label)"
            text += "\u{1B}[\(rows / 2 + 1);3H"
        } else {
            let ruler = (0..<columns).map { String($0 % 10) }.joined()
            let tens = (0..<columns).map { $0 % 10 == 0 ? String(($0 / 10) % 10) : " " }.joined()
            text += tens + "\r\n" + ruler + "\r\n"
            for line in 1...12 {
                let body = "line \(line): " + String(repeating: "=", count: max(0, columns - 20)) + "| end"
                text += String(body.prefix(columns)) + "\r\n"
            }
            text += "$ echo " + String(repeating: "x", count: max(0, columns - 30))
        }
        handler(.output(Data(text.utf8)))
    }

    public func send(_ bytes: Data) {
        // Echo, so typing moves the cursor and the page follows it.
        handler?(.output(bytes))
    }

    public func resize(columns: Int, rows: Int) {}
    public func stop() { handler = nil }
}
#endif
