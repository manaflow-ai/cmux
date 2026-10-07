import CmuxSettings
import SwiftUI

/// The Dock Max Width row's bindings: the override toggle remembers the
/// last custom width so turning it back on restores it.
extension SidebarSection {
    var rightMaxWidthOverrideEnabled: Bool {
        rightMaxWidth.current.isFinite && rightMaxWidth.current > 0
    }
    var rightMaxWidthOverrideBinding: Binding<Bool> {
        Binding(
            get: { rightMaxWidthOverrideEnabled },
            set: { enabled in
                if enabled {
                    let restored = rightSidebarWidthSettings.storedMaximumWidthWhenEnabling(
                        rememberedStoredValue: rememberedRightMaxWidth.current
                    )
                    rememberedRightMaxWidth.set(restored)
                    rightMaxWidth.set(restored)
                } else {
                    rememberedRightMaxWidth.set(
                        rightSidebarWidthSettings.storedRememberedMaximumWidth(
                            activeStoredValue: rightMaxWidth.current,
                            rememberedStoredValue: rememberedRightMaxWidth.current
                        )
                    )
                    rightMaxWidth.set(RightSidebarWidthSettings.noOverrideValue)
                }
            }
        )
    }

    var rightMaxWidthEditorBinding: Binding<Double> {
        Binding(
            get: {
                rightSidebarWidthSettings.editorMaximumWidth(
                    activeStoredValue: rightMaxWidth.current,
                    rememberedStoredValue: rememberedRightMaxWidth.current
                )
            },
            set: {
                let clamped = clampedRightMaxWidth($0)
                rememberedRightMaxWidth.set(clamped)
                if rightMaxWidthOverrideEnabled {
                    rightMaxWidth.set(clamped)
                }
            }
        )
    }

    var rightMaxWidthSubtitle: String {
        String(localized: "settings.sidebar.rightMaxWidth.subtitle", defaultValue: "Lets the Dock in the right sidebar grow up to this width while leaving room for terminals.")
    }

    private func clampedRightMaxWidth(_ value: Double) -> Double {
        rightSidebarWidthSettings.clampedSettingsEditorMaximumWidth(value)
    }
}
