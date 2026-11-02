import CmuxNextCompat
import CmuxUpdater
public import Foundation

/// Switch to any build a Channels track lists, older or newer (Leo 2026-10-23: "and of course be
/// able to hot swap your dev build for any other dev build..."). A kept build swaps at once; any
/// other is downloaded, checked (this app's Developer ID team, bundle id and the build asked
/// for), kept, and then takes the one swap path a rollback takes (``UpdateDropBack``): the stores
/// check, the running build kept so the switch can be undone, one restart with every session.
extension UpdaterService {
    /// Whether this app can switch builds: a release build that runs Sparkle (a local DEV build
    /// follows no feed, and a managed policy that turns updates off turns this off too).
    public var switchesBuilds: Bool {
        identity.sparkleDisabledReason(managedPolicyDisablesUpdates: policy.disablesUpdates) == nil
    }

    /// The Channels card's Switch: restarts into `build`. Nil when it runs (the app quits), else
    /// what the person reads.
    public func switchToBuild(_ build: String) async -> String? {
        guard switchesBuilds else { return UpdaterStrings.channelsSwitchUnavailable }
        guard build != identity.build else { return UpdaterStrings.channelsSwitchAlreadyHere }
        // A directory listing and a read of each kept bundle's Info.plist: file I/O on the files lane.
        let store = keptVersions
        let kept = (try? await work.run(.userVisible, mayBlock: .files) { store.list().contains { $0.build == build } }) ?? false
        if !kept {
            guard let url = await switchDownloadURL(for: build) else { return UpdaterStrings.channelsSwitchGone }
            log.append("switch: downloading \(build) from \(url.absoluteString)")
            if let failure = await BuildSwitchDownload(store: keptVersions, bundleIdentifier: identity.bundleIdentifier,
                                                       teamID: UpdateDropBack.signingTeam(of: Bundle.main.bundleURL))
                .keep(build: build, from: url) {
                log.append("switch: \(build) not kept: \(failure)")
                return UpdaterStrings.channelsSwitchFailed(failure)
            }
        }
        log.append("switch: \(identity.build) -> \(build)")
        return await UpdateDropBack(self).failure(to: build, stateDirectories: pulledWatch.stateDirectories())
    }

    /// Where `build` downloads from: its item in this app's feed, else (cmux NEXT's nightly feed,
    /// which keeps only its newest items) the DMG CI left beside the feed under the build's
    /// number, for a build the feed's notes index lists and the pulled list does not.
    func switchDownloadURL(for build: String) async -> URL? {
        let offered = await feedItems()
        let folder = changelogNotes.map { Self.channelFolder(notesBase: $0.notesBase) }
        if let url = offered.first(where: { $0.version == build })?.downloadURL {
            return url.scheme == "https" ? url : nil
        }
        guard identity.feed().channel == .nightlyNext, !identity.isTipBuild, let folder,
              await (changelogNotes?.index() ?? []).contains(where: { $0.build == build }),
              !(await Self.pulled(in: folder)).contains(where: { $0.build == build })
        else { return nil }
        return Self.nightlyDiskImageURL(build: build, in: folder)
    }

    /// The DMG cmux NEXT's nightly publisher writes for `build` beside its feed; nil for a name
    /// that is not a build number.
    nonisolated static func nightlyDiskImageURL(build: String, in folder: URL,
                                                architecture: UpdateHostArchitecture = .current) -> URL? {
        guard !build.isEmpty, build.allSatisfy(\.isNumber), folder.scheme == "https" else { return nil }
        return folder.appending(path: "cmux-nightly-next-macos-\(architecture.rawValue)-\(build).dmg")
    }
}

/// Downloads one build's DMG and keeps its app beside the builds kept for rollback, after the
/// same checks the channel switch makes of a downloaded app plus the build number.
nonisolated struct BuildSwitchDownload: Sendable {
    var store: KeptVersionStore
    var bundleIdentifier: String?
    /// The running app's signing team; nil (an unsigned app) refuses every download.
    var teamID: String?
    var downloader: any AppChannelDownloading = URLSessionAppChannelDownloader()
    var mounter: any DiskImageMounting = HdiutilDiskImageMounter()
    var inspector: any AppSignatureInspecting = SecurityAppSignatureInspector()
    var temporaryDirectory: URL = FileManager.default.temporaryDirectory

    /// Nil once `build` is kept, else why not. Off the main actor: the download, the mount, the
    /// signature check and the copy of the app all take seconds.
    @concurrent
    func keep(build: String, from url: URL) async -> String? {
        guard let bundleIdentifier, let teamID else { return "this app is not signed" }
        let files = FileManager.checked
        let work = temporaryDirectory.appending(path: "cmux-build-switch-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? files.removeItem(at: work) }
        let image = work.appending(path: "\(build).dmg")
        do {
            try files.createDirectory(at: work, withIntermediateDirectories: true)
            try await downloader.download(from: url, to: image) { _ in }
        } catch {
            return "download failed: \(error)"
        }
        let volume: URL
        do { volume = try await mounter.attach(image) } catch { return "could not open the disk image: \(error)" }
        let failure = keepApp(build: build, volume: volume, bundleIdentifier: bundleIdentifier, teamID: teamID)
        await mounter.detach(volume)
        return failure
    }

    private func keepApp(build: String, volume: URL, bundleIdentifier: String, teamID: String) -> String? {
        let apps = (try? FileManager.checked.contentsOfDirectory(at: volume, includingPropertiesForKeys: nil)) ?? []
        guard let app = apps.first(where: { $0.pathExtension == "app" && Bundle(url: $0)?.bundleIdentifier == bundleIdentifier })
        else { return "the disk image holds no \(bundleIdentifier)" }
        let version = Bundle(url: app)?.infoDictionary?["CFBundleVersion"] as? String
        guard version == build else { return "the disk image holds build \(version ?? "?"), not \(build)" }
        do {
            let report = try inspector.inspect(appURL: app, teamIdentifier: teamID)
            try AppSignatureVerifier(teamIdentifier: teamID).verify(report, bundleIdentifier: bundleIdentifier)
        } catch {
            return "the app's signature does not check: \(error)"
        }
        // Kept without a prune: an older build than every kept one would be pruned at once. The
        // swap that follows prunes when it keeps the running build.
        do { try store.keep(bundle: app, build: build, limit: nil) } catch { return "could not keep it: \(error)" }
        return nil
    }
}

nonisolated extension UpdaterStrings {
    static var channelsSwitch: String { text("updater.channels.switch", "Switch") }
    static var channelsSwitchUnavailable: String {
        text("updater.channels.switchUnavailable", "This build cannot switch builds (it follows no update feed).")
    }
    static var channelsSwitchAlreadyHere: String { text("updater.channels.switchAlreadyHere", "This Mac already runs that build.") }
    static var channelsSwitchGone: String {
        text("updater.channels.switchGone", "That build is no longer offered for download.")
    }
    static func channelsSwitchFailed(_ why: String) -> String {
        format("updater.channels.switchFailed", "Could not switch: %@", why)
    }
}
