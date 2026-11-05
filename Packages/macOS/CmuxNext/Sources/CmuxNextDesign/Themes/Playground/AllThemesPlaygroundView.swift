public import SwiftUI
import CmuxNextDesignTokens

/// The All Themes playground (Debug menu > All Themes Playground, DEV and NIGHTLY): every bundled
/// theme as the App Theme, one row each, every element drawn in its ink on its ground with its
/// contrast; a failing sample (under its minimum, or following the system appearance) is ringed red.
public struct AllThemesPlaygroundView: View {
    @Bindable var model: AllThemesPlaygroundModel

    /// Shows `model`'s themes.
    public init(model: AllThemesPlaygroundModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                TextField(AllThemesPlaygroundStrings.search, text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .focusEffectDisabled()
                    .frame(maxWidth: 260)
                Toggle(AllThemesPlaygroundStrings.failuresOnly, isOn: $model.failuresOnly)
                Spacer()
                Text(AllThemesPlaygroundStrings.summary(failing: model.failingCount, total: model.entries.count))
                    .foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 12)
            ScrollView {
                // Rows take value snapshots only (the snapshot boundary rule).
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(model.shown) { entry in
                        AllThemesPlaygroundRow(entry: entry)
                    }
                }
                .padding(12)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}

/// One theme: its name and mode, then each sample as a chip of its ground with its ink.
struct AllThemesPlaygroundRow: View {
    let entry: AllThemesPlaygroundEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.name).font(.system(size: TypeScale.body, weight: .semibold))
                Text(entry.isDark ? AllThemesPlaygroundStrings.dark : AllThemesPlaygroundStrings.light)
                    .font(.system(size: TypeScale.caption))
                Text(AllThemesPlaygroundStrings.failing(entry.failures.count)).font(.system(size: TypeScale.caption))
                    .opacity(entry.failures.isEmpty ? 0.6 : 1)
            }
            .foregroundStyle(Color(nsColor: entry.foreground.withAlpha(1).nsColor))
            .frame(width: 170, alignment: .leading)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44, maximum: 44), spacing: 4)], alignment: .leading, spacing: 4) {
                ForEach(Array(entry.samples.enumerated()), id: \.offset) { _, sample in
                    AllThemesPlaygroundChip(sample: sample)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: entry.background.withAlpha(1).nsColor)))
    }
}

/// One sample: its ground, the ink as "Aa" (text) or a dot (a mark), and the contrast.
struct AllThemesPlaygroundChip: View {
    let sample: ThemeElementSample

    var body: some View {
        let ink = Color(nsColor: sample.ink.nsColor)
        VStack(spacing: 1) {
            if sample.minimum >= ThemeTokens.minimumTextContrast {
                Text(verbatim: "Aa").font(.system(size: TypeScale.body)).foregroundStyle(ink)
            } else {
                Circle().fill(ink).frame(width: 8, height: 8).padding(.vertical, 3)
            }
            Text(verbatim: String(format: "%.1f", sample.contrast)).font(.system(size: TypeScale.caption).monospacedDigit()).foregroundStyle(ink)
        }
        .frame(width: 44, height: 34)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: sample.surface.nsColor)))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: StatusDotHue.error.hue(isDark: false).nsColor),
                                                                lineWidth: sample.passes ? 0 : 2))
        .themedHelp(AllThemesPlaygroundStrings.sampleHelp(sample))
    }
}
