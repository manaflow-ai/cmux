import CmuxNextSettings
public import Foundation

/// Session Info drawn by the App (Leo, 2026-10-29: "plus we're gonna be doing that part natively in
/// swift anyways?"). The page still reads the chat and works out what each section lists; it sends
/// that as `pane.sessionInfo {info}` (webviews `inspector/native/model.ts`, `NativeSessionInfo`) and
/// draws no panel of its own. ``AgentPaneSessionInfoPanel`` draws it over the pane. A click on a row
/// or button goes back to the page as `sessionInfoAction {id}`, which runs what the page registered
/// for that id. Text, SF Symbol names and ids only: the App interprets none of it.
public nonisolated struct AgentPaneSessionInfoModel: Codable, Equatable, Sendable {
    public enum Tone: String, Codable, Sendable { case running, waiting, failed, done, muted, accent }

    public struct Button: Codable, Equatable, Sendable {
        public var label: String
        public var symbol: String?
        public var action: String
        public var disabled: Bool?
    }

    public struct Row: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var symbol: String?
        public var title: String
        public var detail: String?
        public var subtitle: String?
        public var trailing: String?
        public var tone: Tone?
        public var indent: Int?
        public var meter: Double?
        public var action: String?
        public var buttons: [Button]?
        public var help: String?
    }

    public struct More: Codable, Equatable, Sendable {
        public var label: String
        public var action: String
    }

    public struct Section: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var group: String
        public var title: String
        public var symbol: String?
        public var meta: String?
        public var metaTone: Tone?
        public var meter: Double?
        public var bare: Bool?
        public var open: Bool
        public var foldable: Bool
        public var rows: [Row]
        public var more: More?
    }

    /// The panel shows (its header toggle is on and nothing took the pane).
    public var open: Bool
    /// Its width, CSS pixels.
    public var width: Double
    /// Where it starts below the pane's top, CSS pixels: under the header or the shared tab row.
    public var top: Double
    /// Its distance from the pane's right edge, CSS pixels: a side panel's width beside the chat.
    public var side: Double
    /// Over the chat's column, how far above the pane's foot it stops (the composer's stack), CSS
    /// pixels; nil runs it to the foot less the float margin.
    public var foot: Double?
    /// The panel's accessible name ("Session Info", in the page's language).
    public var label: String
    /// A subagent's own panel names the subagent at its top.
    public var title: String?
    public var sections: [Section]

    /// The page's `info`, nil when it is not a model this App draws (a bad field, a width out of range).
    static func decode(_ value: Any?) -> AgentPaneSessionInfoModel? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let info = try? JSONDecoder().decode(AgentPaneSessionInfoModel.self, from: data),
              info.width.isFinite, (0...4000).contains(info.width),
              info.top.isFinite, (0...4000).contains(info.top),
              info.side.isFinite, (0...8000).contains(info.side),
              info.foot.map({ $0.isFinite && (0...4000).contains($0) }) ?? true,
              info.sections.count <= 32, info.sections.allSatisfy({ $0.rows.count <= 2000 }) else { return nil }
        return info
    }
}

/// A chat's natively drawn Session Info: the last model its page sent and the panel that draws it.
/// Kept on the model: ``AgentPaneView`` is at its size limit.
@MainActor public final class AgentPaneSessionInfo {
    /// What the page last sent; nil while it sends none (an older page, the setting off, no chat).
    public private(set) var info: AgentPaneSessionInfoModel?
    /// The panel while one is made (AgentPaneView+SessionInfo.swift).
    var panel: AgentPaneSessionInfoPanel?
    /// Called when ``info`` changes: the view draws it.
    var onChange: (() -> Void)?

    /// Whether the panel shows.
    public var isOpen: Bool { info?.open == true }

    func update(_ next: AgentPaneSessionInfoModel?) {
        guard next != info else { return }
        info = next
        onChange?()
    }

    /// The page loaded again: it has sent nothing yet.
    func pageLoaded() { update(nil) }
}

extension AgentPageEvent {
    /// The App draws Session Info for this page (`sessionInfoHost`): the page sends its model and
    /// draws no panel of its own.
    static func sessionInfoHost(_ on: Bool) -> AgentPageEvent { AgentPageEvent(kind: "sessionInfoHost", value: .bool(on)) }
    /// The person clicked a row or button the page named `id`, or `action` is one of the panel's own:
    /// `width:<css px>` (a drag of its edge ended), `fold:<section>:<0|1>`, `close`.
    static func sessionInfoAction(_ id: String) -> AgentPageEvent { AgentPageEvent(kind: "sessionInfoAction", value: .string(id)) }
}

extension AgentPaneSessionInfo {
    /// The old host's script for ``AgentPageEvent/sessionInfoHost(_:)``.
    static func hostScript(_ on: Bool) -> String { "window.cmuxAcpmuxSessionInfo?.host?.(\(on));" }
    /// The old host's script for ``AgentPageEvent/sessionInfoAction(_:)``.
    static func actionScript(_ id: String) -> String {
        let quoted = JSONValue.string(id).compactText
        return "window.cmuxAcpmuxSessionInfo?.action?.(\(quoted));"
    }
}
