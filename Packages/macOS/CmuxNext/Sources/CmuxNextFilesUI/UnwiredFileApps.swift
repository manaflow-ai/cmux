public import CmuxNextFiles
public import Foundation

/// ``FileAppsProviding`` with no apps and no opens: the default of a view built without the app's Launch Services
/// answers (tests, previews). Open With then offers Other… only.
public nonisolated struct UnwiredFileApps: FileAppsProviding {
    public init() {}

    public func openWithList(forFileNamed name: String, isDirectory: Bool) async -> OpenWithList {
        OpenWithList(defaultApp: nil, apps: [])
    }

    public func open(_ files: [URL], withApplicationAt app: URL) async -> Bool { false }
}
