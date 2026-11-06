public import Foundation

/// Who drives a Chief's computer: the Chief, or the person who took over (Chief computer take-over).
/// One owner per computer kind: the Worker's ChiefBrainDO for a Cloud Chief's own sandbox
/// (`POST v1/chiefs/<agent>/computer/control`), the app's `ChiefComputerControlStore` for a Cloud
/// machine attached to a Chief on this Mac (`cloud computer-control`). While a person drives, the
/// Chief's input actions are refused; its screenshots are not.
public enum HomeChiefComputerHolder: String, Equatable, Sendable {
    case chief
    case human
}

/// The control lease as the owner reports it.
public struct HomeChiefComputerControlState: Equatable, Sendable {
    public var holder: HomeChiefComputerHolder
    /// When the holder last changed, in ms since 1970; 0 when it never changed.
    public var sinceMs: Int64
    /// Why the Chief asked the person to take over ("Sign in to Gmail"), when it asked.
    public var reason: String?

    public init(holder: HomeChiefComputerHolder, sinceMs: Int64 = 0, reason: String? = nil) {
        self.holder = holder
        self.sinceMs = sinceMs
        self.reason = reason
    }

    public static let chief = HomeChiefComputerControlState(holder: .chief)
}

/// One input the person sends to the Chief's computer while they hold control. Coordinates are
/// in the computer's screen pixels.
public enum HomeChiefComputerInput: Equatable, Sendable {
    case click(x: Int, y: Int, button: Int, count: Int)
    case move(x: Int, y: Int)
    case drag(fromX: Int, fromY: Int, toX: Int, toY: Int)
    /// `direction` is up, down, left or right.
    case scroll(x: Int, y: Int, direction: String, amount: Int)
    case type(String)
    /// A key chord in xdotool form, for example `ctrl+l` or `Return`.
    case key(String)
}

/// What the profile's Computer tab needs to show and change who drives. The app builds one per
/// Chief (`AppServices.chiefComputerControlSource`); the view never talks to a transport itself.
@MainActor
public struct HomeChiefComputerControlSource {
    /// The current lease; nil while it is not known yet.
    public var state: () -> HomeChiefComputerControlState?
    /// Calls `onChange` on the main actor whenever the lease changes. Keep the returned token;
    /// dropping it stops the calls.
    public var observe: (_ onChange: @escaping @MainActor () -> Void) -> AnyObject
    public var takeOver: () async throws -> Void
    public var handBack: () async throws -> Void
    /// Sends one input while the person holds control. Nil when input travels another way (a Cloud
    /// machine's interactive desktop, ``openInteractive``).
    public var send: ((HomeChiefComputerInput) async throws -> Void)?
    /// Opens the computer's full interactive desktop (a Cloud machine). Nil for a sandbox.
    public var openInteractive: (() -> Void)?

    public init(state: @escaping () -> HomeChiefComputerControlState?,
                observe: @escaping (_ onChange: @escaping @MainActor () -> Void) -> AnyObject,
                takeOver: @escaping () async throws -> Void,
                handBack: @escaping () async throws -> Void,
                send: ((HomeChiefComputerInput) async throws -> Void)? = nil,
                openInteractive: (() -> Void)? = nil) {
        self.state = state
        self.observe = observe
        self.takeOver = takeOver
        self.handBack = handBack
        self.send = send
        self.openInteractive = openInteractive
    }
}
