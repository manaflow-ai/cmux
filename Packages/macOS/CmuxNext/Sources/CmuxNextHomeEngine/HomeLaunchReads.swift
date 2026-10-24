package import CmuxHomeCore
package import CmuxNextLaunch
package import Foundation

/// One Chief owner's Home caches, read and decoded off the main thread from the top of `main`
/// (#17587): the conversations (`HomeCache`) and the Home list's last state
/// (``HomeSidebarLaunchCache``, of any account: the list adopts it for its own). The Home list
/// primes from them when it is made, and takes them only when its own files are these.
package nonisolated struct HomeLaunchReads: Sendable {
    /// The conversations' cache file and its read.
    package let cacheURL: URL
    package let cache: LaunchRead<HomeCacheSnapshot?>
    /// The Home list's launch file and its read.
    package let listURL: URL
    package let list: LaunchRead<HomeSidebarLaunchSnapshot?>

    /// Starts both reads now.
    /// - Parameters:
    ///   - owner: The Chief owner's session (`ChiefHome.session`), which names both files.
    ///   - readOnMain: Hears `launch_read_on_main.<file>` when a take waited on the main thread.
    package init(owner: String, readOnMain: @escaping @Sendable (String) -> Void) {
        let cache = HomeCache.standard(owner: owner)
        cacheURL = cache.url
        self.cache = LaunchRead("home_cache", readOnMain: readOnMain) { cache.load() }
        let list = HomeSidebarLaunchCache.standard(owner: owner)
        listURL = list.url
        self.list = LaunchRead("home_list", readOnMain: readOnMain) { list.read() }
    }
}

extension HomeLaunchReads {
    /// Primes `store` (``HomeStore/primeFromCache(_:)``) from this read when the store's cache is
    /// this file, else from its own file.
    @MainActor package func prime(_ store: HomeStore) {
        if store.cache?.url == cacheURL { store.primeFromCache(cache.take()) } else { store.primeFromCache() }
    }

    /// The Home list's last state for `account` (``HomeSidebarLaunchCache/load(account:)``) from this
    /// read when `launchCache` is this file, else from its own file.
    @MainActor package func lastList(_ launchCache: HomeSidebarLaunchCache, account: String) -> HomeSidebarLaunchSnapshot? {
        launchCache.url == listURL ? launchCache.adopt(list.take(), account: account) : launchCache.load(account: account)
    }
}
