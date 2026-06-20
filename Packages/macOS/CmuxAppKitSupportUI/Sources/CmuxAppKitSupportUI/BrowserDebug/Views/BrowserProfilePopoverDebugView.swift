#if canImport(AppKit)

public import SwiftUI

/// The "Browser Profile Popover" debug panel: tunes the profile-popover padding
/// live against a static preview of the popover.
///
/// The view is pure UI over `UserDefaults` (its `@AppStorage` keys are
/// byte-identical to the app target's live profile-popover settings) plus the
/// padding clamping in ``BrowserProfilePopoverDebugPadding``. It needs no
/// app-coupled action seam.
public struct BrowserProfilePopoverDebugView: View {
    @AppStorage(BrowserProfilePopoverDebugPadding.horizontalPaddingKey)
    private var horizontalPaddingRaw = BrowserProfilePopoverDebugPadding.defaultHorizontalPadding
    @AppStorage(BrowserProfilePopoverDebugPadding.verticalPaddingKey)
    private var verticalPaddingRaw = BrowserProfilePopoverDebugPadding.defaultVerticalPadding

    /// Creates the view.
    public init() {}

    private var resolvedPadding: BrowserProfilePopoverDebugPadding {
        BrowserProfilePopoverDebugPadding(rawHorizontal: horizontalPaddingRaw, rawVertical: verticalPaddingRaw)
    }

    private var horizontalPaddingBinding: Binding<Double> {
        Binding(
            get: { BrowserProfilePopoverDebugPadding.clampedHorizontal(horizontalPaddingRaw) },
            set: { horizontalPaddingRaw = BrowserProfilePopoverDebugPadding.clampedHorizontal($0) }
        )
    }

    private var verticalPaddingBinding: Binding<Double> {
        Binding(
            get: { BrowserProfilePopoverDebugPadding.clampedVertical(verticalPaddingRaw) },
            set: { verticalPaddingRaw = BrowserProfilePopoverDebugPadding.clampedVertical($0) }
        )
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(
                    String(
                        localized: "debug.browserProfilePopover.heading",
                        defaultValue: "Browser Profile Popover"
                    )
                )
                .font(.headline)

                Text(
                    String(
                        localized: "debug.browserProfilePopover.note",
                        defaultValue: "Tune the profile popover padding live while comparing it against the browser toolbar menu."
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                GroupBox(
                    String(
                        localized: "debug.browserProfilePopover.group.padding",
                        defaultValue: "Padding"
                    )
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        sliderRow(
                            String(
                                localized: "debug.browserProfilePopover.label.horizontal",
                                defaultValue: "Horizontal"
                            ),
                            value: horizontalPaddingBinding,
                            range: BrowserProfilePopoverDebugPadding.horizontalPaddingRange
                        )
                        sliderRow(
                            String(
                                localized: "debug.browserProfilePopover.label.vertical",
                                defaultValue: "Vertical"
                            ),
                            value: verticalPaddingBinding,
                            range: BrowserProfilePopoverDebugPadding.verticalPaddingRange
                        )
                    }
                    .padding(.top, 2)
                }

                GroupBox(
                    String(
                        localized: "debug.browserProfilePopover.group.preview",
                        defaultValue: "Preview"
                    )
                ) {
                    profilePopoverPreview
                        .padding(.top, 2)
                }

                HStack(spacing: 12) {
                    Button(
                        String(
                            localized: "debug.browserProfilePopover.reset",
                            defaultValue: "Reset"
                        )
                    ) {
                        horizontalPaddingRaw = BrowserProfilePopoverDebugPadding.defaultHorizontalPadding
                        verticalPaddingRaw = BrowserProfilePopoverDebugPadding.defaultVerticalPadding
                    }
                }

                Text(
                    String(
                        localized: "debug.browserProfilePopover.liveNote",
                        defaultValue: "Changes apply live to the browser profile popover."
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var profilePopoverPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "browser.profile.menu.title", defaultValue: "Profiles"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 12, alignment: .center)
                    Text(String(localized: "browser.profile.default", defaultValue: "Default"))
                        .font(.system(size: 12))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.12))
                )
            }

            Divider()

            Text(String(localized: "browser.profile.new", defaultValue: "New Profile..."))
                .font(.system(size: 12))

            Text(String(localized: "menu.view.importFromBrowser", defaultValue: "Import Browser Data…"))
                .font(.system(size: 12))
        }
        .padding(.horizontal, resolvedPadding.horizontal)
        .padding(.vertical, resolvedPadding.vertical)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.primary.opacity(0.08))
                )
        )
    }

    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Text(label)
            Slider(value: value, in: range, step: 1)
            Text(String(format: "%.0f", value.wrappedValue))
                .font(.caption)
                .monospacedDigit()
                .frame(width: 32, alignment: .trailing)
        }
    }
}

#endif
