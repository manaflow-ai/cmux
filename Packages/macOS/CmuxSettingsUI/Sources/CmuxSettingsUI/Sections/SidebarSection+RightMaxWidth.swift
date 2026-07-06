import CmuxSettings
import SwiftUI

/// Dock (right sidebar) max-width row support: the override toggle/editor
/// bindings and subtitle for the "Dock Max Width" row in ``SidebarSection``.
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
        if rightMaxWidthOverrideEnabled {
            return String(localized: "settings.sidebar.rightMaxWidth.subtitleOn", defaultValue: "The Dock can grow past the built-in width cap while preserving terminal space.")
        }
        return String(localized: "settings.sidebar.rightMaxWidth.subtitleOff", defaultValue: "Use the built-in dynamic cap that keeps extra terminal space reserved.")
    }

    private func clampedRightMaxWidth(_ value: Double) -> Double {
        rightSidebarWidthSettings.clampedSettingsEditorMaximumWidth(value)
    }
}
