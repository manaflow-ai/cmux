public import AppKit
public import CmuxNextDesign
import MessagesLabHome

/// The bare launch's stand-in Home (no restored window: a fresh install, or no window open at the
/// last quit) for stage 0's window (`LaunchShell`, `LaunchShellContent`): Home's first frame drawn
/// with AppKit alone (``HomeLaunchBareView``), whose message box takes every key and click before
/// the app's services exist. At the swap its text, caret and sends are parked
/// (``HomeLaunchBareStore``); the real Home's launch page claims them (``HomeLaunchComposer``):
/// the text and caret into its box, the sends to the Chief through ``LaunchChiefHold``, once each,
/// in order.
public enum HomeLaunchBare {
    /// Stage 0's bare content: the stand-in Home, its ready signal (``HomeLaunchBareReady``) and its handoff.
    /// - Parameters:
    ///   - title: The Chief's name under the empty avatar (`HomeStrings.chiefName`).
    ///   - mark: The app's launch marks (`DebugTimings.markLaunch`): what the view's text costs.
    public static func content(title: String, handoff: HomeLaunchBareHandoff,
                               mark: @escaping (String) -> Void) -> LaunchShellContent {
        var content = LaunchShellContent()
        content.bare = { frame, look in
            handoff.store.expect()
            return HomeLaunchBareView(frame: frame, look: look, title: title, placeholder: MessagesLabHomeView.composerPlaceholder, mark: mark)
        }
        content.bareReady = { done in handoff.ready.arm(done) }
        content.handoff = { view in
            guard let view = view as? HomeLaunchBareView else { return }
            handoff.store.park(view.parked)
        }
        return content
    }
}

/// What stage 0's box held at the swap: its text, its selection (UTF-16) and the sends made in it, in order.
public struct HomeLaunchBareParked: Equatable, Sendable {
    public var text: String
    public var selection: NSRange
    public var sends: [String]

    public init(text: String, selection: NSRange, sends: [String]) {
        self.text = text
        self.selection = selection
        self.sends = sends
    }

    public var isEmpty: Bool { text.isEmpty && sends.isEmpty }
}

/// Holds stage 0's box contents from the swap until the real Home claims them, once. Whichever
/// comes second (the park at the swap, or the claim at the page's mount) delivers.
public final class HomeLaunchBareStore {
    /// Takes the parked contents; false: the claimer is gone, so they stay for the next claim.
    public typealias Claimer = (HomeLaunchBareParked) -> Bool

    public private(set) var parked: HomeLaunchBareParked?
    /// Stage 0 drew the stand-in: a claim before the park waits for it.
    public private(set) var expects = false
    private var claimer: Claimer?

    public init() {}

    /// Stage 0 drew the stand-in box (its contents come at the swap).
    public func expect() { expects = true }

    /// The box's contents at the swap. Nothing typed or sent: nothing to claim.
    public func park(_ contents: HomeLaunchBareParked) {
        expects = false
        guard !contents.isEmpty else { return }
        parked = contents
        deliver()
    }

    /// `claimer` takes the contents now, or at the park when stage 0's box is still up. Nothing
    /// parked or coming: does nothing.
    public func claim(by claimer: @escaping Claimer) {
        guard parked != nil || expects else { return }
        self.claimer = claimer
        deliver()
    }

    private func deliver() {
        guard let contents = parked, let claimer else { return }
        self.claimer = nil
        if claimer(contents) { parked = nil }
    }
}

/// Stage 0's swap signal: `LaunchShellContent.bareReady` arms it, and the real Home fires it
/// (its launch page mounted, or its composer took the keyboard). The swap runs once, whichever
/// comes first and however often it fires.
public final class HomeLaunchBareReady {
    private var ready: (@MainActor () -> Void)?
    private var fired = false
    private var done = false

    public init() {}

    /// Stage 0 waits for Home: `ready` runs at the first ``fire()`` (at once if Home is up already).
    public func arm(_ ready: @escaping @MainActor () -> Void) {
        guard !done else { return }
        guard fired else { self.ready = ready; return }
        done = true
        ready()
    }

    /// Home is up in the real window.
    public func fire() {
        guard !done else { return }
        fired = true
        guard let ready else { return }
        done = true
        self.ready = nil
        ready()
    }
}

/// Where the stand-in draws Home's first frame in a fresh 1100 x 720 window (the real window's
/// default), from the real views' geometry: the workspace sidebar (`MetricTunables` compact 208),
/// Home's conversation list (`SidebarModel` 320, at most half the page, a 1 pt divider), and in
/// the transcript column the header (`PaneHeaderView`: a 36 pt disc 4 pt down, the name pill
/// 28 pt high centred 58 pt down) and the message box (`Layout.swift`: 51 pt in from each side,
/// 11 pt above the bottom, one line 30 pt, 31 on macOS 27, corner 15).
public struct HomeLaunchBareLayout: Equatable {
    public static let workspaceSidebar: CGFloat = 208
    public static let homeList: CGFloat = 320
    public static let fieldInset: CGFloat = 51
    public static let fieldBottom: CGFloat = 11
    public static let fieldMaxHeight: CGFloat = 295.5
    public static let lineHeight: CGFloat = 16
    public static var oneLine: CGFloat { ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? 31 : 30 }

    /// The window's content bounds (flipped: y down).
    public let bounds: CGRect

    public init(bounds: CGRect) { self.bounds = bounds }

    public var sidebar: CGRect { CGRect(x: 0, y: 0, width: min(Self.workspaceSidebar, bounds.width), height: bounds.height) }
    public var list: CGRect {
        let page = bounds.width - sidebar.width
        return CGRect(x: sidebar.maxX, y: 0, width: max(0, min(Self.homeList, page / 2)), height: bounds.height)
    }
    public var divider: CGRect { CGRect(x: list.maxX, y: 0, width: 1, height: bounds.height) }
    public var column: CGRect { CGRect(x: divider.maxX, y: 0, width: max(0, bounds.width - divider.maxX), height: bounds.height) }
    public var avatar: CGRect { CGRect(x: column.midX - 18, y: 4, width: 36, height: 36) }
    public func pill(width: CGFloat) -> CGRect { CGRect(x: column.midX - width / 2, y: 58 - 14, width: width, height: 28) }
    /// The box at `lines` lines of text (it grows up, as the real one does).
    public func field(lines: Int) -> CGRect {
        let height = min(Self.fieldMaxHeight, Self.oneLine + Self.lineHeight * CGFloat(max(1, lines) - 1))
        return CGRect(x: column.minX + Self.fieldInset, y: column.maxY - Self.fieldBottom - height,
                      width: max(0, column.width - 2 * Self.fieldInset), height: height)
    }
}

/// Stage 0's stand-in box contents and its swap signal for one launch: made by the app's
/// composition root (`AppDelegate`), given to stage 0's content and to Home (`HomeService.launchBare`).
public final class HomeLaunchBareHandoff {
    public let store = HomeLaunchBareStore()
    public let ready = HomeLaunchBareReady()

    public init() {}
}
