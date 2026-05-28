import CmuxSettings
import SwiftUI

/// Visual grid picker for ``AppIconMode``.
///
/// Mirrors the legacy in-app App Icon grid: each option renders as a
/// rounded square with a system-symbol placeholder (icon art lives in
/// the host app's asset catalog and isn't bundled in the package),
/// the selected option is highlighted with an accent border, and
/// tapping commits through the supplied ``DefaultsValueModel``.
@MainActor
public struct AppIconGridPicker: View {
    private let model: DefaultsValueModel<AppIconMode>

    public init(model: DefaultsValueModel<AppIconMode>) {
        self.model = model
    }

    public var body: some View {
        HStack(spacing: 12) {
            ForEach(AppIconMode.allCases, id: \.self) { mode in
                tile(for: mode)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func tile(for mode: AppIconMode) -> some View {
        let isSelected = model.current == mode
        Button {
            model.set(mode)
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(background(for: mode))
                        .frame(width: 56, height: 56)
                    Image(systemName: symbol(for: mode))
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(foreground(for: mode))
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                )
                Text(displayName(for: mode))
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            }
        }
        .buttonStyle(.plain)
        .help(displayName(for: mode))
    }

    private func displayName(for mode: AppIconMode) -> String {
        switch mode {
        case .automatic: return "Automatic"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    private func symbol(for mode: AppIconMode) -> String {
        switch mode {
        case .automatic: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    private func background(for mode: AppIconMode) -> Color {
        switch mode {
        case .automatic: return Color(nsColor: .controlBackgroundColor)
        case .light: return Color(red: 0.95, green: 0.95, blue: 0.92)
        case .dark: return Color(red: 0.08, green: 0.08, blue: 0.10)
        }
    }

    private func foreground(for mode: AppIconMode) -> Color {
        switch mode {
        case .automatic: return .secondary
        case .light: return .orange
        case .dark: return .yellow
        }
    }
}
