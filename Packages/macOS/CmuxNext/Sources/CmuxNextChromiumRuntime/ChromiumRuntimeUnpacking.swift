public import Foundation

/// Lists and extracts a pack archive.
///
/// ``TarChromiumRuntimeUnpacker`` runs `/usr/bin/tar`; tests can use it on a
/// small archive they make, or a fake.
public protocol ChromiumRuntimeUnpacking: Sendable {
    /// Every entry name in `archive`, as stored.
    func entries(of archive: URL) async throws(ChromiumRuntimeInstallError) -> [String]
    /// Extracts `archive` into the empty folder `directory`.
    func unpack(_ archive: URL, into directory: URL) async throws(ChromiumRuntimeInstallError)
}
