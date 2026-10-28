public import CmuxHomeCore
import CmuxNextDesign
public import CmuxNextWakeups
public import Foundation

/// The Home list's two launch files, read together on a launch lane from `main` while AppKit starts
/// (p08-startup-076): the conversations' ``HomeCache`` (`home.json` and its windows) and the list's
/// ``HomeSidebarLaunchCache`` (`sidebar.json`). The main thread never reads them: the Home list's first
/// frame takes ``value`` when the read has ended, and otherwise seeds the list on the read's completion
/// (the theme background until then), as Chrome reads a profile's files on a blocking sequence and runs
/// what needs them from the loaded callback (chrome/browser/profiles/profile_impl.cc).
///
/// ```swift
/// let read = HomeListLaunchRead.start(owner: home.session, caches: caches, on: work)  // main()
/// if let value = read.value { store.primeFromCache(value.conversations) }           // never waits
/// ```
public nonisolated struct HomeListLaunchRead: Sendable {
    /// What the two files held.
    public nonisolated struct Value: Sendable {
        /// The conversations, their opened windows, sends and drafts (``HomeCache/load()``).
        public var conversations: HomeCacheSnapshot?
        /// The list's state beyond the conversations, of any account (``HomeSidebarLaunchCache/read()``):
        /// the caller shows it only for its own account.
        public var sidebar: HomeSidebarLaunchSnapshot?

        public init(conversations: HomeCacheSnapshot? = nil, sidebar: HomeSidebarLaunchSnapshot? = nil) {
            self.conversations = conversations
            self.sidebar = sidebar
        }
    }

    /// The Chief owner the files belong to (`ChiefHome.session`).
    public let owner: String
    /// The folder of the Home caches the files are in.
    public let caches: URL
    /// The conversations' cache the read read: the Home store writes through this one.
    public let conversations: HomeCache
    /// The list's launch cache the read read: the Home list writes through this one, so an unchanged list is not written.
    public let sidebar: HomeSidebarLaunchCache
    /// The read on the files lane; nil for a folder with nothing to read (``nothingToRead(owner:caches:)``).
    private let read: LaunchRead<Value>?

    /// Starts the read of `owner`'s two files under `caches` on `work`'s files lane.
    ///
    /// - Parameters:
    ///   - owner: The Chief owner (`ChiefHome.session`).
    ///   - caches: The folder of the Home caches (the user's Caches folder in the app).
    ///   - work: The app's blocking-work lanes.
    ///   - reads: Asked on the lane before the files are read; false reads neither and gives an empty ``Value``
    ///     (the app's crash-streak safe launch, `LaunchSafeMode`).
    /// - Returns: The read in flight.
    public static func start(owner: String, caches: URL, on work: BackgroundWork,
                             reads: @escaping @Sendable () -> Bool = { true }) -> HomeListLaunchRead {
        let conversations = HomeCache.standard(owner: owner, caches: caches)
        let sidebar = HomeSidebarLaunchCache.standard(owner: owner, caches: caches, files: work)
        return HomeListLaunchRead(owner: owner, caches: caches, conversations: conversations, sidebar: sidebar, on: work) {
            reads() ? Value(conversations: conversations.load(), sidebar: sidebar.read()) : Value()
        }
    }

    /// The read of a folder made for one service only, which holds no file yet (a test's `AppServices`): it has
    /// ended, empty, so the list lands in the turn it is asked for and no lane reads a folder that is known empty.
    ///
    /// - Parameters:
    ///   - owner: The Chief owner (`ChiefHome.session`).
    ///   - caches: The new folder of the Home caches.
    ///   - work: The app's blocking-work lanes, which write the list's launch cache.
    /// - Returns: The ended read.
    public static func nothingToRead(owner: String, caches: URL, on work: BackgroundWork) -> HomeListLaunchRead {
        HomeListLaunchRead(owner: owner, caches: caches, conversations: HomeCache.standard(owner: owner, caches: caches),
                           sidebar: HomeSidebarLaunchCache.standard(owner: owner, caches: caches, files: work), read: nil)
    }

    private init(owner: String, caches: URL, conversations: HomeCache, sidebar: HomeSidebarLaunchCache, read: LaunchRead<Value>?) {
        self.owner = owner
        self.caches = caches
        self.conversations = conversations
        self.sidebar = sidebar
        self.read = read
    }

    /// Starts `body` on `work`'s files lane as the read of `conversations` and `sidebar` (tests pass one that is held).
    ///
    /// - Parameters:
    ///   - owner: The Chief owner the files belong to.
    ///   - caches: The folder of the Home caches.
    ///   - conversations: The conversations' cache.
    ///   - sidebar: The list's launch cache.
    ///   - work: The app's blocking-work lanes.
    ///   - body: The blocking read; it runs on a lane thread. Quit before it started gives an empty ``Value``.
    public init(owner: String, caches: URL, conversations: HomeCache, sidebar: HomeSidebarLaunchCache, on work: BackgroundWork,
                _ body: @escaping @Sendable () -> Value) {
        self.init(owner: owner, caches: caches, conversations: conversations, sidebar: sidebar,
                  read: LaunchRead(on: work, dropped: Value(), body))
    }

    /// Whether this is the read of `owner`'s files under `caches`.
    public func reads(owner: String, caches: URL) -> Bool {
        self.owner == owner && self.caches.standardizedFileURL == caches.standardizedFileURL
    }

    /// What the files held once the read ended; nil while it runs.
    public var value: Value? {
        guard let read else { return Value() }
        return read.value
    }

    /// What the files held, once the read ended (the caller suspends; no thread waits).
    public func finished() async -> Value { await read?.finished() ?? Value() }
}
