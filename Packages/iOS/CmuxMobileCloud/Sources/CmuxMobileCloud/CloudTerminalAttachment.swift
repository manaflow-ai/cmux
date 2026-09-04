public import Foundation

/// Input side of one attached terminal.
///
/// Output flows through the handler given to
/// ``CloudMachineConnection/attach(terminalID:output:)``; this object carries
/// keystrokes and grid reports back and ends the attachment.
public final class CloudTerminalAttachment: Sendable {
    /// The attached terminal's id.
    public let terminalID: String
    private let session: any CloudTerminalSession

    init(session: any CloudTerminalSession, terminalID: String) {
        self.session = session
        self.terminalID = terminalID
    }

    /// Queue input bytes.
    public func send(_ bytes: Data) {
        session.send(bytes)
    }

    /// Report the phone's natural grid.
    public func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        session.resize(cols: cols, rows: rows)
    }

    /// Stop streaming output. The link stays open for the catalog.
    public func detach() {
        session.detach()
    }
}
