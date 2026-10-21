public import CmuxNextSettings
public import Foundation

/// A design mode highlight for a chat's composer (plans/cmux-next/design-mode-DESIGN.md): the page
/// adds it as chips (`designSelection.ts`), a text chip with what the agent reads and an image chip
/// with the element's crop, and sends them with the next message. The same `id` replaces the chips.
public nonisolated struct AgentPaneDesignSelection: Sendable, Equatable {
    /// Stable per highlighted element (`design-<hash>`); the image chip is `<id>-shot`.
    public let id: String
    /// The chip's name, `Design: <tag> · <host>`.
    public let name: String
    /// What the agent reads.
    public let text: String
    /// The element's crop as PNG, nil when the page could not be captured.
    public let png: Data?

    public init(id: String, name: String, text: String, png: Data?) {
        self.id = id
        self.name = name
        self.text = text
        self.png = png
    }

    /// The `designSelection` event's value: `{id, name, text, image?: {mimeType, data}}`.
    public var pageValue: JSONValue {
        var value: [String: JSONValue] = ["id": .string(id), "name": .string(name), "text": .string(text)]
        if let png {
            value["image"] = ["mimeType": .string("image/png"), "data": .string(png.base64EncodedString())]
        }
        return .object(value)
    }

    /// Adds the highlight to `view`'s composer (not an AgentPaneView extension: that type is at its
    /// size limit).
    /// Takes highlight `id`'s chips out of `view`'s composer (the highlight left the page).
    @MainActor public static func remove(_ id: String, from view: AgentPaneView) {
        let value: JSONValue = ["removed": .string(id)]
        view.deliver([AgentPageEvent(kind: "designSelection", value: value)],
                     scripts: ["window.cmuxAcpmuxBridge?.designSelection?.(\(value.compactText));"])
    }

    @MainActor public func push(to view: AgentPaneView) {
        let event = AgentPageEvent(kind: "designSelection", value: pageValue)
        view.deliver([event], scripts: ["window.cmuxAcpmuxBridge?.designSelection?.(\(pageValue.compactText));"])
    }
}
