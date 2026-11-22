@testable import CmuxNextApp

/// One step of a fuzz run. Parameters are indices resolved against the
/// world at run time (modulo the live count), so any subsequence of a run
/// is still a valid run: that is what makes shrinking work.
enum FuzzAction: Hashable, CustomStringConvertible {
    // The daemon (another client, the CLI, a process exit).
    case daemonNewTab(pane: Int, browser: Bool)
    case daemonCloseTab(tab: Int)
    case daemonSplit(pane: Int, browser: Bool)
    case daemonClosePane(pane: Int)
    case daemonMoveTab(tab: Int, pane: Int)
    /// A pending delta or command response arrives (any order).
    case deliver(Int)
    /// A pending delta or response never arrives (rejected, failed).
    case reject(Int)
    // The user.
    case userSplit(window: Int, browser: Bool)
    case userNewTab(window: Int, browser: Bool)
    case userCloseTab(window: Int)
    case userMoveTab(window: Int, pane: Int)
    case clickPane(window: Int, pane: Int)
    /// The Chromium page window of `pane` becomes key without a click
    /// (Chromium activating its page, AppKit restoring key). `placed`:
    /// false while the page window is not over its pane yet (just created),
    /// so the applier cannot tell which pane it is. `parented`: false while
    /// the fork has not made it a child window yet (it hid it over a parent
    /// view without bounds; Chromium's activation shows it parentless).
    case pageTakesKey(window: Int, pane: Int, placed: Bool, parented: Bool = true)
    case clickTab(window: Int, pane: Int, tab: Int)
    case clickSidebar(window: Int, field: Bool)
    case otherTextField(window: Int)
    case keyNav(window: Int, pane: Int)
    case cmdL(window: Int)
    case find(window: Int)
    case escape(window: Int)
    case enter(window: Int)
    case type
    case cliFocusPane(window: Int, pane: Int)
    /// `stalePane`: the CLI read the tab's pane from an older snapshot.
    case cliSelectTab(window: Int, tab: Int, stalePane: Int?)
    case keyWindow(window: Int)
    case appActive(Bool)
    case openPalette
    case closePalette
    case paletteFocusPane(pane: Int)
    case openSheet(window: Int)
    case closeSheet(window: Int)
    case openGroupEditor(window: Int)
    case closeGroupEditor
    case switchWorkspace(window: Int)
    case dragBegin(window: Int)
    /// 0 cancel, 1 drop in another pane's strip, 2 new split, 3 other window, 4 reorder in place.
    case dragEnd(kind: Int, target: Int)
    case focusMode(window: Int)
    case frame
    /// 0 opened, 1 open failed, 2 replay, 3 overflow, 4 visibility, 5 late open, 6 focused,
    /// 7 another client's grid, 8 other end.
    case attach(terminal: Int, event: Int)

    var description: String {
        switch self {
        case .pageTakesKey(let window, let pane, let placed, let parented):
            "pageTakesKey(window: \(window), pane: \(pane), placed: \(placed), parented: \(parented))"
        case .daemonNewTab(let pane, let browser): "daemonNewTab(pane: \(pane), browser: \(browser))"
        case .daemonCloseTab(let tab): "daemonCloseTab(tab: \(tab))"
        case .daemonSplit(let pane, let browser): "daemonSplit(pane: \(pane), browser: \(browser))"
        case .daemonClosePane(let pane): "daemonClosePane(pane: \(pane))"
        case .daemonMoveTab(let tab, let pane): "daemonMoveTab(tab: \(tab), pane: \(pane))"
        case .deliver(let index): "deliver(\(index))"
        case .reject(let index): "reject(\(index))"
        case .userSplit(let window, let browser): "userSplit(window: \(window), browser: \(browser))"
        case .userNewTab(let window, let browser): "userNewTab(window: \(window), browser: \(browser))"
        case .userCloseTab(let window): "userCloseTab(window: \(window))"
        case .userMoveTab(let window, let pane): "userMoveTab(window: \(window), pane: \(pane))"
        case .clickPane(let window, let pane): "clickPane(window: \(window), pane: \(pane))"
        case .clickTab(let window, let pane, let tab): "clickTab(window: \(window), pane: \(pane), tab: \(tab))"
        case .clickSidebar(let window, let field): "clickSidebar(window: \(window), field: \(field))"
        case .otherTextField(let window): "otherTextField(window: \(window))"
        case .keyNav(let window, let pane): "keyNav(window: \(window), pane: \(pane))"
        case .cmdL(let window): "cmdL(window: \(window))"
        case .find(let window): "find(window: \(window))"
        case .escape(let window): "escape(window: \(window))"
        case .enter(let window): "enter(window: \(window))"
        case .type: "type"
        case .cliFocusPane(let window, let pane): "cliFocusPane(window: \(window), pane: \(pane))"
        case .cliSelectTab(let window, let tab, let stale): "cliSelectTab(window: \(window), tab: \(tab), stalePane: \(stale.map(String.init) ?? "nil"))"
        case .keyWindow(let window): "keyWindow(window: \(window))"
        case .appActive(let active): "appActive(\(active))"
        case .openPalette: "openPalette"
        case .closePalette: "closePalette"
        case .paletteFocusPane(let pane): "paletteFocusPane(pane: \(pane))"
        case .openSheet(let window): "openSheet(window: \(window))"
        case .closeSheet(let window): "closeSheet(window: \(window))"
        case .openGroupEditor(let window): "openGroupEditor(window: \(window))"
        case .closeGroupEditor: "closeGroupEditor"
        case .switchWorkspace(let window): "switchWorkspace(window: \(window))"
        case .dragBegin(let window): "dragBegin(window: \(window))"
        case .dragEnd(let kind, let target): "dragEnd(kind: \(kind), target: \(target))"
        case .focusMode(let window): "focusMode(window: \(window))"
        case .frame: "frame"
        case .attach(let terminal, let event): "attach(terminal: \(terminal), event: \(event))"
        }
    }

    /// A random action (weights favor the paths where races live).
    static func random(_ random: inout SplitMix) -> FuzzAction {
        let w = random.int(3)
        let n = random.int(8)
        let m = random.int(8)
        let flag = random.bool()
        switch random.int(44) {
        case 0: return .daemonNewTab(pane: n, browser: flag)
        case 1: return .daemonCloseTab(tab: n)
        case 2: return .daemonSplit(pane: n, browser: flag)
        case 3: return .daemonClosePane(pane: n)
        case 4: return .daemonMoveTab(tab: n, pane: m)
        case 5, 6, 7: return .deliver(n)
        case 8: return .reject(n)
        case 9: return .userSplit(window: w, browser: flag)
        case 10: return .userNewTab(window: w, browser: flag)
        case 11: return .userCloseTab(window: w)
        case 12: return .userMoveTab(window: w, pane: n)
        case 13, 14: return .clickPane(window: w, pane: n)
        case 15: return .clickTab(window: w, pane: n, tab: m)
        case 16: return .clickSidebar(window: w, field: flag)
        case 17: return .otherTextField(window: w)
        case 18: return .keyNav(window: w, pane: n)
        case 19: return .cmdL(window: w)
        case 20: return .find(window: w)
        case 21: return .escape(window: w)
        case 22: return .enter(window: w)
        case 23, 24: return .type
        case 25: return .cliFocusPane(window: w, pane: n)
        case 26: return .cliSelectTab(window: w, tab: n, stalePane: flag ? m : nil)
        case 27: return .keyWindow(window: w)
        case 28: return .appActive(flag)
        case 29: return .openPalette
        case 30: return .closePalette
        case 31: return .paletteFocusPane(pane: n)
        case 32: return flag ? .openSheet(window: w) : .closeSheet(window: w)
        case 33: return flag ? .openGroupEditor(window: w) : .closeGroupEditor
        case 34: return .switchWorkspace(window: w)
        case 35: return .dragBegin(window: w)
        case 36: return .dragEnd(kind: n % 5, target: m)
        case 37: return .focusMode(window: w)
        case 38, 39, 40: return .frame
        default: return .attach(terminal: n, event: random.int(9))
        }
    }
}

/// Deterministic generator (SplitMix64) so every run reproduces from its seed.
struct SplitMix {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ bound: Int) -> Int { Int(next() % UInt64(max(bound, 1))) }
    mutating func bool() -> Bool { next() & 1 == 0 }
}
