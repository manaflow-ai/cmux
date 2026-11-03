import Foundation

/// The parsed arguments of `cmux open-remote <host>` (manaflow-ai/cmux#25092).
///
/// `label` is Rex's name for `name`; `name` wins when both are given. `ratio` is the new
/// pane's share (0 to 1) and `focus: false` keeps the user's focus where it was.
public nonisolated struct OpenRemoteRequest: Sendable, Equatable {
    public enum Failure: Error, Equatable, Sendable {
        case missingHost
        case unsupportedSplit(String)
        case badRatio(String)
    }

    public let host: String
    public let placement: OpenRemotePlacement
    public let ratio: Double?
    public let focus: Bool
    public let cwd: String?
    public let cmd: String?
    public let name: String?
    public let attach: String?

    /// The identity of the pane this request makes: running it again finds that pane
    /// instead of making a second one. The attach name, else the name, under the host.
    public var key: String {
        let host = self.host.lowercased()
        guard let label = (attach ?? name)?.lowercased() else { return host }
        return host + "/" + label
    }

    /// - Throws: ``Failure`` for a missing host, a split word the daemon cannot place, or a bad ratio.
    public init(_ invocation: ActionInvocation) throws {
        func text(_ key: String) -> String? {
            guard let value = invocation[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        guard let host = text("host") else { throw Failure.missingHost }
        self.host = host
        switch text("split")?.lowercased() {
        case nil, "tab": placement = .tab
        case "right": placement = .right
        case "down", "below", "bottom": placement = .down
        case let word?: throw Failure.unsupportedSplit(word)
        }
        if let raw = text("ratio") ?? invocation["ratio"]?.intValue.map(String.init) {
            guard let value = Double(raw), value > 0, value < 1 else { throw Failure.badRatio(raw) }
            ratio = value
        } else {
            ratio = nil
        }
        // `--focus=false` arrives as a bool from the CLI and as text from a script.
        focus = invocation["focus"]?.boolValue ?? text("focus").map { $0.lowercased() != "false" } ?? true
        cwd = text("cwd")
        cmd = text("cmd")
        name = text("name") ?? text("label")
        attach = text("attach")
    }

    /// Whether a remote-terminal tab is the pane this request makes: the tab of the same
    /// attach name or name; with neither, the unnamed tab that still wears the default title.
    public func matchesTab(name tabName: String?, title: String, defaultTitle: String) -> Bool {
        if let label = (attach ?? name)?.lowercased() { return tabName?.lowercased() == label }
        return tabName == nil && title == defaultTitle
    }
}
