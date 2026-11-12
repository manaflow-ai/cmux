public import Foundation

/// The person's answer turned to `off` anywhere (Settings' row, the palette, `cmux settings set
/// agents.cmuxMcp off`, MCP's settings tools: every write goes through the app's settings owner):
/// cmux's own entry comes out of their agents' configs (`cmux setup mcp --remove`), so no means no
/// cmux tools in the person's agents, whichever surface said it. Only a change to `off` runs it,
/// once per change; the answer at launch is the starting point, not a change.
@MainActor
public final class AgentToolsOffFollower {
    private let source: any AgentToolsSource
    private var last: AgentToolsChoice?
    /// The removals this follower started (for tests and the log).
    public private(set) var removals = 0

    public init(source: any AgentToolsSource) {
        self.source = source
    }

    /// Feeds each answer the settings file holds, in order (the first is the launch's).
    public func follow<Choices: AsyncSequence & Sendable>(_ choices: Choices) async where Choices.Element == AgentToolsChoice {
        do {
            for try await next in choices {
                await observe(next)
            }
        } catch {
            return
        }
    }

    /// One answer read from the settings file: a change to `off` takes cmux's entry out.
    public func observe(_ next: AgentToolsChoice) async {
        defer { last = next }
        guard let last, last != .off, next == .off else { return }
        removals += 1
        _ = await source.applyAgentTools(remove: true)
    }
}
