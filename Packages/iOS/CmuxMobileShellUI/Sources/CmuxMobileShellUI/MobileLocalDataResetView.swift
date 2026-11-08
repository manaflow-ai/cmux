#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// Where the root is in an "erase all local data" reset.
enum MobileLocalDataResetPhase: Equatable {
    case erasing
    case finished
    /// Some data could not be erased. Any data already erased stays erased, and
    /// the next launch retries whatever the marker covers.
    case failed
}

/// Replaces the whole app UI once a reset starts. The app root's live objects
/// were built from the erased state, so the only safe next step is a relaunch;
/// the next launch finishes the erase before anything reads local data.
struct MobileLocalDataResetView: View {
    let phase: MobileLocalDataResetPhase
    let retry: () -> Void

    var body: some View {
        switch phase {
        case .erasing:
            ProgressView {
                Text(L10n.string(
                    "mobile.localDataReset.erasing",
                    defaultValue: "Erasing cmux data on this device…"
                ))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("MobileLocalDataResetErasing")
        case .finished:
            ContentUnavailableView {
                Label(
                    L10n.string("mobile.localDataReset.finished.title", defaultValue: "cmux Was Reset"),
                    systemImage: "checkmark.circle"
                )
            } description: {
                Text(L10n.string(
                    "mobile.localDataReset.finished.message",
                    defaultValue: "All cmux data on this device was erased. Your cmux account and server data were not changed. Close cmux from the App Switcher, then open it again to start fresh."
                ))
            }
            .accessibilityIdentifier("MobileLocalDataResetFinished")
        case .failed:
            ContentUnavailableView {
                Label(
                    L10n.string("mobile.localDataReset.failed.title", defaultValue: "Couldn’t Erase All Data"),
                    systemImage: "exclamationmark.triangle"
                )
            } description: {
                Text(L10n.string(
                    "mobile.localDataReset.failed.message",
                    defaultValue: "Some cmux data on this device could not be erased. Try again. Your cmux account and server data were not changed."
                ))
            } actions: {
                Button(L10n.string("mobile.localDataReset.failed.retry", defaultValue: "Try Again"), action: retry)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("MobileLocalDataResetRetry")
            }
            .accessibilityIdentifier("MobileLocalDataResetFailed")
        }
    }
}
#endif
