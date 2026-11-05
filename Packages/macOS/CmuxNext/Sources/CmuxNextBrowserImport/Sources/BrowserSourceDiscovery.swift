public import Foundation
import CmuxNextCompat

/// Finds browser data folders no registry row names, so a new Chromium fork
/// or an Electron app (Claude, Slack, VS Code) is a source without a new row.
/// Looks one and two levels into `~/Library/Application Support` for a
/// Chromium user data folder (`Local State` beside a profile with history or
/// cookies, or with them in the folder itself) or a Firefox-family folder
/// (`profiles.ini`). Reads folder listings and file existence only.
public struct BrowserSourceDiscovery: Sendable {
    public var environment: ImportEnvironment

    public init(environment: ImportEnvironment) {
        self.environment = environment
    }

    /// Browsers found on disk that `known` does not cover, by name.
    public func browsers(known: [ImportBrowser] = ImportBrowser.allCases) -> [ImportBrowser] {
        #if CMUX_NO_BROWSER_DATA_IMPORT
        // The cx-f58x notary test build detects no browser.
        return []
        #else
        let support = environment.homeDirectory.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        let knownPaths = Set(known.flatMap(\.dataDirectories).map {
            canonical(environment.homeDirectory.appending(path: $0, directoryHint: .isDirectory))
        })
        var found: [ImportBrowser] = []
        for name in listing(support) {
            guard !Task.isCancelled else { return [] }
            let folder = support.appending(path: name, directoryHint: .isDirectory)
            if knownPaths.contains(canonical(folder)) { continue }
            if let browser = browser(at: folder, relative: [name]) {
                found.append(browser)
                continue
            }
            // Vendor folders (Google/, BraveSoftware/, Arc/User Data): one level more.
            for child in listing(folder) {
                let inner = folder.appending(path: child, directoryHint: .isDirectory)
                guard !knownPaths.contains(canonical(inner)) else { continue }
                if let browser = browser(at: inner, relative: [name, child]) { found.append(browser) }
            }
        }
        return found.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        #endif
    }

    /// The source a folder holds, or nil when it holds no browser data.
    func browser(at folder: URL, relative: [String]) -> ImportBrowser? {
        let engine: BrowserFamily
        let profiles: ProfileDiscovery
        if exists(folder.appending(path: "Local State")) {
            let listed = ChromiumProfileList().entries(in: folder).filter { !$0.directoryName.isEmpty }
            if listed.contains(where: { hasChromiumData(folder.appending(path: $0.directoryName, directoryHint: .isDirectory)) }) {
                profiles = .chromiumLocalState
            } else if hasChromiumData(folder) {
                // Electron: the data folder is the one profile.
                profiles = .dataDirectory
            } else {
                return nil
            }
            engine = .chromium
        } else if exists(folder.appending(path: "profiles.ini")), !FirefoxProfileList().entries(in: folder).isEmpty {
            engine = .firefox
            profiles = .firefoxProfilesIni
        } else {
            return nil
        }
        // "Arc/User Data", "com.example.app/browser-data/host": the app's own folder names it.
        let generic: Set<String> = ["User Data", "browser-data", "host", "Default"]
        let stem = relative.last { !generic.contains($0) } ?? relative[0]
        let app = application(named: stem)
        let row = BrowserSourceRow(
            id: Self.id(relative), name: app?.name ?? stem, vendor: "", kind: profiles == .dataDirectory ? .appWithEmbeddedBrowser : .browser,
            engine: engine, bundleIDs: app?.bundleID.map { [$0] } ?? [], appNames: [app?.fileName ?? stem], verified: false,
            dataDirectories: ["Library/Application Support/" + relative.joined(separator: "/")], profiles: profiles,
            bookmarks: profiles == .dataDirectory ? .noStore : nil, files: nil, sidebarFile: nil, cookieFile: nil,
            safeStorage: nil, unsupportedKinds: nil, refusesSessionData: nil, evidence: [])
        return ImportBrowser(row: row)
    }

    /// `found.<folder path>`, lowercased, so ids stay stable and carry no `/` or `:`.
    static func id(_ relative: [String]) -> String {
        let text = relative.joined(separator: "-").lowercased().unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character($0) : "-"
        }
        return "found." + String(text)
    }

    /// Whether a Chromium profile folder has data cmux imports.
    private func hasChromiumData(_ profile: URL) -> Bool {
        ["History", "Bookmarks", "Login Data"].contains { exists(profile.appending(path: $0)) }
            || BrowserSourceDetector.chromiumCookieFile(profile) != nil
    }

    /// The installed app for a folder name: its shown name, bundle id and file name.
    private func application(named stem: String) -> (name: String, bundleID: String?, fileName: String)? {
        let url = environment.locateAppNamed(stem) ?? environment.locateApp(stem)
        guard let url else { return nil }
        let plist = (try? Data(blockingContentsOf: url.appending(path: "Contents/Info.plist"))) ?? Data()
        let info = (try? PropertyListSerialization.propertyList(from: plist, format: nil)) as? [String: Any] ?? [:]
        let fileName = url.deletingPathExtension().lastPathComponent
        let shown = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
        return (shown.flatMap { $0.isEmpty ? nil : $0 } ?? fileName, info["CFBundleIdentifier"] as? String, fileName)
    }

    /// Folder names, without hidden ones and without cmux's own browser data.
    private func listing(_ folder: URL) -> [String] {
        let names = (try? FileManager.checked.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { name in
            let lower = name.lowercased()
            return !name.hasPrefix(".") && !lower.hasPrefix("cmux") && !lower.hasPrefix("com.cmuxterm") && !lower.hasPrefix("cef")
        }.sorted()
    }

    private func exists(_ url: URL) -> Bool { FileManager.checked.fileExists(atPath: url.path) }

    private func canonical(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
}
