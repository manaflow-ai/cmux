import Foundation
import Testing

/// The size of the session a count test runs on. ONE definition for every owner: a suite that counts what a change
/// wakes, walks or builds takes its size from here and never writes its own "800" (two owners that each add a fixture
/// give a duplicate symbol or two different sessions; that happened with `LargeSessionFixture`).
///
/// - `large`: the session of plans/cmux-next/main-thread-scheduling.md 1.5: 60 workspaces x 6 tabs (3 terminals, 1 agent
///   chat, 1 Chromium page, 1 WebKit page), 5 agent terminals. The tests written for 60 keep their meaning.
/// - `real`: the session of the person who uses the app, read from his one session daemon on 2026-11-10: 826
///   workspaces, 858 panes, 1600 tabs, 798 terminals, 170 agents. 14 times `large`. A count test must be
///   O(shown + changed) here as at 60.
///
/// The mix rule of `real` (``shape(_:)``), with ``pick(_:_:of:)`` spreading each "K of N" evenly:
/// 1. 798 of the 826 workspaces start with a terminal; the other 28 hold one agent chat and nothing else.
/// 2. 170 of the 798 terminals are agent terminals (a program in them reports an agent's state).
/// 3. 774 of the 798 terminal workspaces have a second tab; its kind cycles agent chat, Chromium page, WebKit page
///    (258 each). So a workspace has one agent chat at most, and ``LargeSessionFixture/session(_:)`` names it as at 60.
/// 4. In 32 of those 774 the second tab is in a second pane (826 + 32 = 858 panes).
/// Sums: 798 terminals + 28 + 258 agent chats + 258 Chromium + 258 WebKit pages = 1600 tabs. ``mixFaults`` checks them.
/// The last workspace (the one a window fixture shows) starts with a terminal that is not an agent terminal.
///
/// Which arms a parameterised suite runs (``arms``): `large` only, unless the environment of the test run names them:
///
///     CMUX_TEST_SESSION_SIZES=real swift test --filter "LargeSessionObservationTests|LargeSessionSpinnerWakeTests"
///     CMUX_TEST_SESSION_SIZES=large,real swift test --filter ...
///
/// Why `real` is not a default arm: CI runs the default, and this must add no CI time and no CI red (no new gate or
/// test in CI; each owner runs the `real` arm on a mini and writes the result in its row). A test that is O(session)
/// at 826 is a finding for the owner of that path; it must not turn the base red for everyone. The variable picks a
/// test arm; the app does not read it.
///
/// `nonisolated`: a value and pure functions of it; a `@Test(arguments:)` list and a tree builder's closure read it off
/// the main actor.
nonisolated enum SessionFixtureSize: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case large
    case real

    /// One tab of a workspace's shape.
    nonisolated enum Tab: Sendable, Hashable {
        case terminal
        /// A terminal in which a program reports an agent's state. The tree lists it as any terminal.
        case agentTerminal
        case chat
        case chromium
        case webkit

        var isTerminal: Bool { self == .terminal || self == .agentTerminal }
    }

    /// The names in `CMUX_TEST_SESSION_SIZES` (comma separated).
    private static let named: [String] = (ProcessInfo.processInfo.environment["CMUX_TEST_SESSION_SIZES"] ?? "")
        .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

    /// The arms a parameterised suite runs: the sizes `CMUX_TEST_SESSION_SIZES` names, in its order, else `large`.
    static let arms: [SessionFixtureSize] = {
        var arms: [SessionFixtureSize] = []
        for size in named.compactMap(SessionFixtureSize.init(rawValue:)) where !arms.contains(size) { arms.append(size) }
        return arms.isEmpty ? [.large] : arms
    }()

    /// The names in `CMUX_TEST_SESSION_SIZES` that are no size. ``mixFaults`` lists them, so every test that uses a
    /// size fails: a typo must never look like a run of `real`.
    static let unknownArms: [String] = named.filter { SessionFixtureSize(rawValue: $0) == nil }

    var testDescription: String { "\(rawValue) (\(workspaces) workspaces)" }

    var workspaces: Int { self == .large ? 60 : 826 }

    /// Picks exactly `k` of the positions `0..<n`, evenly, for `1 <= k <= n` (no other `k` is used): position `i` is
    /// picked when `i * k / n` (rounded down) is more than at `i - 1`, and position 0 is picked. Returns the picked
    /// position's rank (`0..<k`), nil for a position that is not picked.
    static func pick(_ i: Int, _ k: Int, of n: Int) -> Int? {
        let rank = i * k / n
        return i == 0 || rank > (i - 1) * k / n ? rank : nil
    }

    /// The panes of workspace `workspace` (1...``workspaces``) and the tabs of each, in order.
    func shape(_ workspace: Int) -> [[Tab]] {
        switch self {
        case .large:
            // The agent terminals are the first terminal of workspaces 1, 13, 25, 37 and 49.
            let first: Tab = (workspace - 1) % 12 == 0 ? .agentTerminal : .terminal
            return [[first, .terminal, .terminal], [.chat, .chromium, .webkit]]
        case .real:
            guard let terminal = Self.pick(workspace - 1, 798, of: 826) else { return [[.chat]] }
            let first: Tab = Self.pick(terminal, 170, of: 798) == nil ? .terminal : .agentTerminal
            guard let second = Self.pick(terminal, 774, of: 798) else { return [[first]] }
            let kinds: [Tab] = [.chat, .chromium, .webkit]
            let page = kinds[second % 3]
            return Self.pick(second, 32, of: 774) == nil ? [[first, page]] : [[first], [page]]
        }
    }

    /// Every workspace's tabs of one kind: (workspace, index of the tab in the workspace).
    func places(where matches: (Tab) -> Bool) -> [(workspace: Int, index: Int)] {
        var places: [(workspace: Int, index: Int)] = []
        for workspace in 1...workspaces {
            for (index, tab) in shape(workspace).joined().enumerated() where matches(tab) {
                places.append((workspace: workspace, index: index))
            }
        }
        return places
    }

    /// The panes of ``shape(_:)``: what ``LargeSessionFixture`` (the store fixture) makes at both sizes and
    /// ``LargeSessionWindowFixture`` makes at `real`. At `large` the window fixture joins each workspace's tabs into
    /// one pane, as before the sizes: 60 panes there, not 120.
    var panes: Int { (1...workspaces).map { shape($0).count }.reduce(0, +) }
    var tabs: Int { places { _ in true }.count }
    var terminals: Int { places { $0.isTerminal }.count }
    var agentTerminals: Int { places { $0 == .agentTerminal }.count }
    var chats: Int { places { $0 == .chat }.count }
    var chromiumPages: Int { places { $0 == .chromium }.count }
    var webkitPages: Int { places { $0 == .webkit }.count }
    /// The workspaces that start with a terminal, in order.
    var terminalWorkspaces: [Int] { (1...workspaces).filter { shape($0)[0][0].isTerminal } }

    /// What ``shape(_:)`` gives against the session's stated size; empty when the mix is right. A fixture requires it
    /// empty, so a change of the rule that moves a sum fails every test that uses the size.
    var mixFaults: [String] {
        // panes, tabs, terminals, agent terminals, agent chats, Chromium pages, WebKit pages
        let names = ["panes", "tabs", "terminals", "agent terminals", "agent chats", "Chromium pages", "WebKit pages"]
        let stated = self == .large ? [120, 360, 180, 5, 60, 60, 60] : [858, 1600, 798, 170, 286, 258, 258]
        let made = [panes, tabs, terminals, agentTerminals, chats, chromiumPages, webkitPages]
        var faults: [String] = []
        for (index, name) in names.enumerated() where made[index] != stated[index] {
            faults.append("\(name): \(made[index]), not \(stated[index])")
        }
        if shape(workspaces)[0][0] != .terminal { faults.append("the last workspace does not start with a plain terminal") }
        for workspace in 1...workspaces where shape(workspace).joined().filter({ $0 == .chat }).count > 1 {
            faults.append("workspace \(workspace) has more than one agent chat")
        }
        for name in Self.unknownArms { faults.append("CMUX_TEST_SESSION_SIZES names \(name), which is no session size (large, real)") }
        return faults
    }
}
