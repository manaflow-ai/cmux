public import Foundation

extension URL {
    /// A stable identity for an application URL used to deduplicate and compare
    /// "open with" application entries: the symlink-resolved, standardized file
    /// path. Two URLs that resolve to the same on-disk application bundle share
    /// this identity even if one is an alias or relative form.
    public var fileExternalOpenApplicationIdentity: String {
        resolvingSymlinksInPath().standardizedFileURL.path
    }
}
