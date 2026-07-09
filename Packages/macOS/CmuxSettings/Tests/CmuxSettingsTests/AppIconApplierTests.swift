import Foundation
import Testing
@testable import CmuxSettings

@MainActor
@Suite("AppIconApplier")
struct AppIconApplierTests {
    private func makeStore() -> AppIconSettingsStore {
        let suite = UserDefaults(suiteName: "AppIconApplierTests.\(UUID().uuidString)")!
        return AppIconSettingsStore(defaults: suite)
    }

    @Test func applyDarkPinsManualIconStopsObservationAndNotifies() {
        var manualModes: [AppIconMode] = []
        var startCount = 0
        var stopCount = 0
        var notifyCount = 0
        let applier = AppIconApplier(
            store: makeStore(),
            environment: AppIconApplier.Environment(
                isApplicationFinishedLaunching: { true },
                applyManualIcon: { manualModes.append($0) },
                startAppearanceObservation: { startCount += 1 },
                stopAppearanceObservation: { stopCount += 1 },
                notifyDockTilePlugin: { notifyCount += 1 }
            )
        )

        applier.apply(.dark)

        #expect(manualModes == [.dark])
        #expect(startCount == 0)
        #expect(stopCount == 1)
        #expect(notifyCount == 1)
    }

    @Test func applyAutomaticStartsObservationWithoutPinningIcon() {
        var startCount = 0
        var stopCount = 0
        var notifyCount = 0
        var manualCount = 0
        let applier = AppIconApplier(
            store: makeStore(),
            environment: AppIconApplier.Environment(
                isApplicationFinishedLaunching: { true },
                applyManualIcon: { _ in manualCount += 1 },
                startAppearanceObservation: { startCount += 1 },
                stopAppearanceObservation: { stopCount += 1 },
                notifyDockTilePlugin: { notifyCount += 1 }
            )
        )

        applier.apply(.automatic)

        #expect(manualCount == 0)
        #expect(startCount == 1)
        #expect(stopCount == 0)
        #expect(notifyCount == 1)
    }

    @Test func applyBeforeLaunchIsANoOp() {
        var touched = false
        let applier = AppIconApplier(
            store: makeStore(),
            environment: AppIconApplier.Environment(
                isApplicationFinishedLaunching: { false },
                applyManualIcon: { _ in touched = true },
                startAppearanceObservation: { touched = true },
                stopAppearanceObservation: { touched = true },
                notifyDockTilePlugin: { touched = true }
            )
        )

        applier.apply(.dark)

        #expect(touched == false)
    }

    @Test func resolvedModeReadsPersistedValue() {
        let suite = UserDefaults(suiteName: "AppIconApplierTests.\(UUID().uuidString)")!
        suite.set(AppIconMode.dark.rawValue, forKey: AppCatalogSection().appIcon.userDefaultsKey)
        let applier = AppIconApplier(
            store: AppIconSettingsStore(defaults: suite),
            environment: AppIconApplier.Environment(
                isApplicationFinishedLaunching: { false },
                applyManualIcon: { _ in },
                startAppearanceObservation: {},
                stopAppearanceObservation: {},
                notifyDockTilePlugin: {}
            )
        )

        #expect(applier.resolvedMode == .dark)
    }
}
