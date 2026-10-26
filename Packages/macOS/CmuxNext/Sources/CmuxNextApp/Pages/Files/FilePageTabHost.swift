import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextPages
import CmuxNextSettings
import Foundation

extension FilePageService {
    // MARK: Quit hook (R96)

    fileprivate func edited(_ url: URL, text: String, baseHash: String?, writable: Bool, from key: String) -> RecoveryDraftAcceptance {
        guard let document = documents.document(for: url, holder: holder(key), writable: { [weak self] in self?.tabs[key]?.provider?.isWritable ?? writable }) else {
            tabs[key]?.editsUnsaved = true
            return .invalidID
        }
        if tabs[key]?.stopFlush == nil, let page = tabs[key]?.page {
            let op = kind.op("flush")
            tabs[key]?.stopFlush = document.addFlusher { [weak page] in
                guard let page, let answer = try? await page.router.callPage(op, params: .object([:])) else { return true }
                return answer["dirty"]?.boolValue ?? true
            }
        }
        let accepted = document.edited(text: text, baseHash: baseHash)
        // A draft the quit hook refused is still an edit the page has not saved.
        tabs[key]?.editsUnsaved = accepted == .invalidID || document.hasUnsavedChanges
        if accepted == .tooLarge, warnedTooLarge.insert(url.path).inserted, let window = tabs[key]?.page?.window {
            _ = CmuxToastCenter.shared.show(CmuxToast(id: "file-recovery:\(url.path)", message: FilePageStrings.noRecovery(url.lastPathComponent),
                                                     duration: .seconds(8)), in: window)
        }
        return accepted
    }

    fileprivate func saved(_ url: URL, hash: String) {
        documents.existing(url)?.saved(hash: hash)
        // A save can change the file's git state (clean to modified).
        for tab in tabs.values where tab.provider?.file == url { tab.bar?.refresh() }
        savedEdits(of: url)
    }

    // MARK: Host services for the tabs

    /// Every terminal folder of every window (diff-host.md: the workspace roots).
    var roots: FileWorkspaceRoots { Self.userChosenRoots(services) }

    /// Folders the user chose as roots (the `files.roots` setting); never home, `/` or a folder the
    /// host infers (a terminal's working directory).
    static func userChosenRoots(_ services: AppServices) -> FileWorkspaceRoots {
        let folders = services.settings?.fileRoot["files"]?["roots"]?.arrayValue?.compactMap(\.stringValue) ?? []
        return FileWorkspaceRoots(folders: folders.map { ($0 as NSString).expandingTildeInPath })
    }

    fileprivate func confirmOpen(_ url: URL, userGesture: Bool, from key: String) async -> Bool {
        let page = tabs[key]?.page
        return await openConfirmation.confirm(url, userGesture: userGesture, gestureEvent: page?.lastUserEventUptime, anchor: page)
    }

    fileprivate func recents() -> JSONValue {
        JSONValue(foundation: services.viewers.recents.hostOpValue(kind.recents)) ?? ["items": []]
    }

    fileprivate func chooseFile(start: URL?, for key: String) async -> URL? {
        var start = start
        if start == nil, let newest = services.viewers.recents.paths(kind.recents).first {
            start = URL(fileURLWithPath: newest).deletingLastPathComponent()
        }
        if kind == .markdown { return await services.viewers.chooseMarkdownFile(start: start?.path).map { URL(fileURLWithPath: $0) } }
        let options = CmuxPicker.OpenOptions(choose: .files, startDirectory: start, recents: [.file, .markdown])
        return await services.viewers.picker.open(options, over: tabs[key]?.page?.window)?.first
    }

    fileprivate func openAppLink(_ url: URL) -> Bool {
        CmuxAppLinks.open(url, services: services)
    }
}

/// One tab's ``FilePageHosting``: the service, scoped to that tab.
final class FilePageTabHost: FilePageHosting {
    private weak var service: FilePageService?
    private let key: String

    init(service: FilePageService, key: String) {
        self.service = service
        self.key = key
    }

    var roots: FileWorkspaceRoots { service?.roots ?? FileWorkspaceRoots(folders: []) }
    var remoteImages: Bool { service?.look.remoteImages ?? false }
    func recents() -> JSONValue { service?.recents() ?? ["items": []] }
    func record(_ url: URL) {
        guard let service else { return }
        service.servicesRecord(url)
    }
    func chooseFile(start: URL?) async -> URL? { await service?.chooseFile(start: start, for: key) }
    func look() -> JSONValue { service?.look.current() ?? .object([:]) }
    func listenLook(_ onLook: @escaping @MainActor (JSONValue) -> Void) -> () -> Void { service?.look.listen(onLook) ?? {} }
    func setPreference(key: String, value: JSONValue, by writer: SettingWriter) async throws {
        try await service?.look.setPreference(key: key, value: value, by: writer)
    }
    func opened(_ url: URL) { service?.opened(url, in: key) }
    func openExternal(_ url: URL) { service?.openExternal(url, from: key) }
    func openFile(_ url: URL) { service?.openFile(url, from: key) }
    func openAppLink(_ url: URL) -> Bool { service?.openAppLink(url) ?? false }
    func edited(_ url: URL, text: String, baseHash: String?, writable: Bool) -> RecoveryDraftAcceptance {
        service?.edited(url, text: text, baseHash: baseHash, writable: writable, from: key) ?? .kept
    }
    func saved(_ url: URL, hash: String) { service?.saved(url, hash: hash) }
    var showsOmnibar: Bool { service?.kind == .markdown }
    func historyChanged(canBack: Bool, canForward: Bool) { service?.historyChanged(canBack: canBack, canForward: canForward, in: key) }
    func isRecent(_ path: String) -> Bool { service?.isRecent(path) ?? false }
    func confirmOpen(_ url: URL, userGesture: Bool) async -> Bool { await service?.confirmOpen(url, userGesture: userGesture, from: key) ?? false }
}

extension FilePageService {
    fileprivate func servicesRecord(_ url: URL) {
        services.viewers.recents.record(url, as: kind.recents)
    }
}
