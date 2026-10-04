import CmuxNextDesign
import CmuxNextSettings
import SwiftUI

struct AppearanceTunerCard: View {
    let model: SettingsWindowModel
    let onPeek: (AppearanceTuningAxis) -> Void
    let onTuningChanged: (AppearanceTuning) -> Void
    let initialTuning: AppearanceTuning

    @ViewBuilder var body: some View {
        if let descriptor = SettingsSchema.descriptor(for: ExperimentalAppearanceSetting().configPath),
           model.value(descriptor)?.boolValue == true {
            SettingsCard(title: nil) {
            AppearanceTunerView(initial: initialTuning, onChange: onTuningChanged, onPeek: onPeek)
                .padding(.horizontal, Metrics.space5)
                .padding(.vertical, Metrics.space3)
            }
        }
    }
}
