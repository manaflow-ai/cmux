import AppKit
import SwiftUI
import Observation
import Darwin
import Bonsplit
import UniformTypeIdentifiers

struct SettingsPickerRow<SelectionValue: Hashable, PickerContent: View, ExtraTrailing: View>: View {
    let configurationReview: SettingsConfigurationReview
    let title: String
    let subtitle: String?
    let controlWidth: CGFloat
    @Binding var selection: SelectionValue
    let pickerContent: PickerContent
    let extraTrailing: ExtraTrailing
    let accessibilityId: String?

    init(
        configurationReview: SettingsConfigurationReview,
        _ title: String,
        subtitle: String? = nil,
        controlWidth: CGFloat,
        selection: Binding<SelectionValue>,
        accessibilityId: String? = nil,
        @ViewBuilder content: () -> PickerContent,
        @ViewBuilder extraTrailing: () -> ExtraTrailing
    ) {
        configurationReview.validate()
        self.configurationReview = configurationReview
        self.title = title
        self.subtitle = subtitle
        self.controlWidth = controlWidth
        self._selection = selection
        self.pickerContent = content()
        self.extraTrailing = extraTrailing()
        self.accessibilityId = accessibilityId
    }

    var body: some View {
        SettingsCardRow(configurationReview: configurationReview, title, subtitle: subtitle, controlWidth: controlWidth) {
            HStack(spacing: 6) {
                Picker("", selection: $selection) {
                    pickerContent
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .applyIf(accessibilityId != nil) { $0.accessibilityIdentifier(accessibilityId!) }
                extraTrailing
            }
        }
    }
}

extension SettingsPickerRow where ExtraTrailing == EmptyView {
    init(
        configurationReview: SettingsConfigurationReview,
        _ title: String,
        subtitle: String? = nil,
        controlWidth: CGFloat,
        selection: Binding<SelectionValue>,
        accessibilityId: String? = nil,
        @ViewBuilder content: () -> PickerContent
    ) {
        self.init(configurationReview: configurationReview, title, subtitle: subtitle, controlWidth: controlWidth, selection: selection, accessibilityId: accessibilityId, content: content) {
            EmptyView()
        }
    }
}
