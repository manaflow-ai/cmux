public import CmuxNextBrowserImport
public import Foundation
import os

/// Extensions: each imported source profile's extensions go into the cmux profile its data went
/// to. The plan (`chromium.extension_install_plan`, the cmux-browser-import crate) leaves out what
/// that profile already has, so importing the same browser again adds nothing twice. Unpacked ones
/// are copied from their folder (read only: the source is never written) and loaded from the copy.
/// Web Store ones open as a workspace of their store pages in that profile, after its extensions
/// page, where the store's own Add to cmux installs each: the store asks the person to confirm
/// every install, and cmux has no silent install from it.
public struct ImportedExtensionsInstaller {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "import.extensions")

    let reader: BrowserDataReader
    /// A cmux profile's Chromium folder and the folder its unpacked copies go to; nil when the id
    /// is not a browser profile.
    let folders: @MainActor (String) -> (profile: URL, copies: URL)?
    /// Loads copied folders into the profile with that id.
    let load: @MainActor ([String], String) -> Void

    public init(reader: BrowserDataReader, folders: @escaping @MainActor (String) -> (profile: URL, copies: URL)?,
                load: @escaping @MainActor ([String], String) -> Void) {
        self.reader = reader
        self.folders = folders
        self.load = load
    }

    /// The summary's open-tab workspaces, then one workspace per source whose extensions brought
    /// something new: the extensions page and each store page left to install.
    public func workspaces(_ summary: ImportSummary) async -> [ImportedTabsWorkspace] {
        var result = summary.tabWorkspaces
        for batch in summary.batches where batch.kinds.contains(.extensions) && !batch.extensions.isEmpty {
            let target = batch.source.targetProfileID
            guard let folders = folders(target) else { continue }
            let plan: ExtensionInstallPlan
            do {
                plan = try await reader.extensionInstallPlan(batch.extensions, profile: folders.profile, copyRoot: folders.copies)
            } catch {
                Self.logger.error("extension plan failed: \(String(describing: error), privacy: .public)")
                continue
            }
            let copied = await Self.copy(plan.unpacked)
            load(copied, target)
            Self.logger.notice("""
                extensions: store \(plan.store.count, privacy: .public), unpacked \(copied.count, privacy: .public) of \
                \(plan.unpacked.count, privacy: .public), already there \(plan.installed, privacy: .public)
                """)
            guard !plan.store.isEmpty || !copied.isEmpty else { continue }
            result.append(ImportedTabsWorkspace(name: OnboardingStrings.extensionsWorkspace(batch.source.displayName), profileID: target,
                                                tabs: Self.pages(plan.store), chromium: true))
        }
        return result
    }

    /// The extensions page first (what came over, and a page of the profile that lets an unpacked
    /// copy load), then each store page.
    nonisolated static func pages(_ store: [ImportedExtension]) -> [ImportedTab] {
        let manage = URL(string: "chrome://extensions/").map { ImportedTab(url: $0, title: nil, window: 0, pinned: false) }
        return [manage].compactMap { $0 } + store.compactMap { ext in
            ext.webStorePage.map { ImportedTab(url: $0, title: ext.name, window: 0, pinned: false) }
        }
    }

    /// Copies each unpacked folder to its plan folder off the main thread; answers the copies made.
    @concurrent
    nonisolated static func copy(_ unpacked: [ExtensionInstallPlan.Copy]) async -> [String] {
        unpacked.compactMap { item in
            guard let source = item.extension.unpackedPath, copyFolder(from: source, to: item.copy) else { return nil }
            return item.copy
        }
    }

    /// `source` (read only) to `destination` through a sibling staging folder, so a half copy never
    /// sits where a load would find it; a copy an earlier import left is replaced. False when the
    /// source has no manifest (moved or deleted) or the copy failed.
    nonisolated static func copyFolder(from source: String, to destination: String) -> Bool {
        let files = FileManager.default
        let from = URL(fileURLWithPath: source, isDirectory: true)
        let to = URL(fileURLWithPath: destination, isDirectory: true)
        guard files.fileExists(atPath: from.appending(path: "manifest.json", directoryHint: .notDirectory).path) else { return false }
        let parent = to.deletingLastPathComponent()
        let staging = parent.appending(path: ".\(to.lastPathComponent).\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try files.createDirectory(at: parent, withIntermediateDirectories: true)
            try files.copyItem(at: from, to: staging)
            if files.fileExists(atPath: to.path) { try files.removeItem(at: to) }
            try files.moveItem(at: staging, to: to)
            return true
        } catch {
            try? files.removeItem(at: staging)
            return false
        }
    }
}
