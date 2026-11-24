import AppKit
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextDictation
import CmuxNextParakeet
import CmuxNextSettings
import Foundation

/// Labs > Parakeet Dictation (`labs.parakeetDictation`, docs/design/voice-byo-providers.md slice 3):
/// while on, every dictation surface uses ``ParakeetDictationTranscriber`` instead of On This Mac.
/// Turning it on downloads the model once, shown as a progress toast with Cancel and then its size on
/// disk; turning it off cancels a download, frees the model's memory and gives dictation back to On This
/// Mac. The default (off) changes nothing.
@MainActor
enum ParakeetDictation {
    private static let toastID = "labs.parakeetDictation"
    private static var store: ParakeetModelStore?
    private static var showsDownload = false
    private static var shown: CmuxToastHandle?

    static func follow(_ settings: SettingsController, services: AppServices) {
        // task-owner: lives as long as the app's settings; event-driven (Observation).
        Task { [weak settings, weak services] in
            guard let settings else { return }
            for await on in ObservationStream({ settings.snapshot.parakeetDictation }) {
                guard let services else { return }
                await apply(on, services: services)
            }
        }
    }

    private static func apply(_ on: Bool, services: AppServices) async {
        guard on else {
            DictationEngineChoice.engine = nil
            showsDownload = false
            await store?.unload()
            return
        }
        guard ParakeetModelStore.isSupported else {
            DictationEngineChoice.engine = nil
            toast(services, ParakeetDictationStrings.unsupported, duration: .seconds(6))
            return
        }
        let store = makeStore(services)
        DictationEngineChoice.engine = { meter in ParakeetDictationTranscriber(store: store, levelMeter: meter) }
        // On disk already: the first dictation loads it; nothing to show.
        if case .ready = await store.state { return }
        showsDownload = true
        await store.prepare()
    }

    private static func makeStore(_ services: AppServices) -> ParakeetModelStore {
        if let store { return store }
        let made = ParakeetModelStore(directory: DaemonLauncher.nextSupport()
            .appending(path: "speech-models/parakeet-v3", directoryHint: .isDirectory))
        store = made
        let (states, sink) = AsyncStream<ParakeetModelStore.State>.makeStream(bufferingPolicy: .bufferingNewest(1))
        // task-owner: lives as long as the app (the store is never released); one state at a time, in order.
        Task { [weak services] in
            await made.observe { sink.yield($0) }
            for await state in states {
                guard let services else { return }
                show(state, services: services)
            }
        }
        return made
    }

    private static func show(_ state: ParakeetModelStore.State, services: AppServices) {
        switch state {
        case .notDownloaded:
            // Cancelled: the toast's Cancel or Esc on a dictation that started the download.
            if showsDownload { shown?.dismiss() }
            showsDownload = false
        case .downloading(let fraction):
            showsDownload = true
            let handle = toast(services, ParakeetDictationStrings.downloading(percent: Int((fraction * 100).rounded(.down))),
                               duration: .seconds(600), action: ParakeetDictationStrings.cancel, working: true)
            handle?.onAction = { Task { await store?.cancel() } }
        case .preparing:
            guard showsDownload else { return }
            toast(services, ParakeetDictationStrings.preparing, duration: .seconds(600), working: true)
        case .ready(let bytes):
            guard showsDownload else { return }
            showsDownload = false
            toast(services, ParakeetDictationStrings.ready(size: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)),
                  duration: .seconds(8))
        case .failed(let reason):
            showsDownload = false
            let handle = toast(services, ParakeetDictationStrings.failed, detail: reason, duration: .seconds(12),
                               action: ParakeetDictationStrings.retry)
            handle?.onAction = { Task { await store?.prepare() } }
        }
    }

    @discardableResult
    private static func toast(_ services: AppServices, _ message: String, detail: String? = nil, duration: Duration,
                              action: String? = nil, working: Bool = false) -> CmuxToastHandle? {
        guard let window = services.windows.active?.window ?? NSApp.mainWindow else { return nil }
        shown = CmuxToastCenter.shared.show(CmuxToast(id: toastID, message: message, detail: detail,
                                                     action: action.map { CmuxToast.Action(title: $0) },
                                                     duration: duration, oneWindow: true, working: working), in: window)
        return shown
    }
}

enum ParakeetDictationStrings {
    static func downloading(percent: Int) -> String {
        String(format: String(localized: "parakeetDictation.downloading", defaultValue: "Downloading the Parakeet speech model: %lld%%",
                              table: "VoiceRoom", bundle: .module.inAppLanguage), percent)
    }

    static var preparing: String {
        String(localized: "parakeetDictation.preparing", defaultValue: "Preparing the Parakeet speech model for this Mac…",
               table: "VoiceRoom", bundle: .module.inAppLanguage)
    }

    static func ready(size: String) -> String {
        String(format: String(localized: "parakeetDictation.ready", defaultValue: "Parakeet Dictation is ready. The model uses %@ on this Mac.",
                              table: "VoiceRoom", bundle: .module.inAppLanguage), size)
    }

    static var failed: String {
        String(localized: "parakeetDictation.failed", defaultValue: "The Parakeet speech model did not download.",
               table: "VoiceRoom", bundle: .module.inAppLanguage)
    }

    static var unsupported: String {
        String(localized: "parakeetDictation.unsupported", defaultValue: "Parakeet Dictation needs a Mac with Apple silicon.",
               table: "VoiceRoom", bundle: .module.inAppLanguage)
    }

    static var cancel: String {
        String(localized: "parakeetDictation.cancel", defaultValue: "Cancel", table: "VoiceRoom", bundle: .module.inAppLanguage)
    }

    static var retry: String {
        String(localized: "parakeetDictation.retry", defaultValue: "Try Again", table: "VoiceRoom", bundle: .module.inAppLanguage)
    }
}
