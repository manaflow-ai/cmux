#if canImport(SwiftUI)
import SwiftUI
#endif

// A page's oversized tool output comes cut to its head (`ACPToolOutputCut`, cmux-tui acpmux
// `hub/tool_output_cut.rs`); opening the output reads the whole record (`AgentChatStore
// .loadFullOutput(of:)`) and puts it in place, so nothing the person sees stays cut.

extension Array where Element == TurnItem {
    /// Puts `full`'s output in place of the call's cut one; false when no call here still shows
    /// that cut (it is elsewhere, or a newer update replaced its output).
    mutating func placeFullOutput(_ full: ACPToolCallUpdate, cut: ACPToolOutputCut) -> Bool {
        guard let index = lastIndex(where: {
            if case .tool(let call) = $0 { call.id == full.toolCallId && call.outputCut == cut } else { false }
        }), case .tool(var call) = self[index] else { return false }
        if let content = full.content { call.content = content }
        if let rawOutput = full.rawOutput { call.rawOutput = rawOutput }
        call.outputCut = full.outputCut
        self[index] = .tool(call)
        return true
    }
}

#if os(iOS)
/// Reads a cut tool output whole (the transcript's store); a view outside a store's transcript
/// shows the cut output.
public struct LoadFullToolOutputAction: Sendable {
    let handler: @MainActor @Sendable (ACPToolCall) async -> Bool

    public init(_ handler: @escaping @MainActor @Sendable (ACPToolCall) async -> Bool) {
        self.handler = handler
    }

    /// False when the whole output could not be read.
    @MainActor public func callAsFunction(_ call: ACPToolCall) async -> Bool {
        await handler(call)
    }
}

extension EnvironmentValues {
    @Entry public var loadFullToolOutput = LoadFullToolOutputAction { _ in false }
}
#endif
