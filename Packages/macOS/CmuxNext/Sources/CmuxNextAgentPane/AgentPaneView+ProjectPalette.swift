public import AppKit
import Foundation
import CmuxNextSettings

extension AgentPaneView {
    func projectPalette(_ method: String, params: JSONValue, person: Bool) -> JSONValue {
        let refused = JSONValue.object(["shown": .bool(false)])
        guard let request = AgentProjectPaletteRequest(method: method, params: params), let onProjectPaletteRequest else {
            return refused
        }
        switch request.operation {
        case .show:
            guard person, window != nil, !isHiddenOrHasHiddenAncestor else { return refused }
            guard onProjectPaletteRequest(request) else { return refused }
            projectPaletteID = request.id
            return .object(["shown": .bool(true)])
        case .update, .close:
            guard projectPaletteID == request.id else { return refused }
            return .object(["shown": .bool(onProjectPaletteRequest(request))])
        }
    }

    /// Sends palette input back to the originating composer through its existing host transport.
    public func sendProjectPaletteEvent(_ event: AgentProjectPaletteEvent, session: String, input: NSEvent? = nil) {
        if let input, ProcessInfo.processInfo.systemUptime - input.timestamp <= AgentPaneUserGestures.lifetime {
            AgentPanePersonInput.record(model.transport.gestures, sources: eventSources, event: input)
        }
        if event == .closed, projectPaletteID == session { projectPaletteID = nil }
        let payload = event.payload(session: session)
        deliver([AgentPageEvent(kind: "projectPalette", value: payload)], scripts: [projectPaletteScript(payload)])
    }

    func dismissProjectPalette() {
        guard let id = projectPaletteID else { return }
        _ = projectPalette("projectPalette.close", params: .object(["id": .string(id)]), person: false)
        projectPaletteID = nil
    }

    private func projectPaletteScript(_ payload: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(payload) else { return "" }
        let json = String(decoding: data, as: UTF8.self)
        return "window.dispatchEvent(new CustomEvent('cmux-project-palette', {detail: \(json)}))"
    }
}
