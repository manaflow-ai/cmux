#if canImport(AppKit)

public import SwiftUI

/// The "Browser Import Hint" debug panel: previews blank-tab import-hint variants
/// and dismissal states without touching the permanent Browser settings home.
///
/// The view is pure UI over `UserDefaults` (its `@AppStorage` keys are
/// byte-identical to the app target's live import-hint settings), plus three
/// app-coupled quick actions routed through the injected ``BrowserDebugContext``
/// seam. It owns no reference to the application delegate, the import coordinator,
/// or the app-target settings namespaces.
public struct BrowserImportHintDebugView: View {
    @AppStorage(BrowserImportHintVariant.storageKey)
    private var variantRaw = BrowserImportHintVariant.defaultVariant.rawValue
    @AppStorage(BrowserImportHintPresentation.showOnBlankTabsKey)
    private var showOnBlankTabs = BrowserImportHintPresentation.defaultShowOnBlankTabs
    @AppStorage(BrowserImportHintPresentation.dismissedKey)
    private var isDismissed = BrowserImportHintPresentation.defaultDismissed

    private let context: (any BrowserDebugContext)?

    /// Creates the view.
    ///
    /// - Parameter context: The seam backing the panel's quick-action buttons.
    ///   When `nil`, the buttons are no-ops (used by previews/tests).
    public init(context: (any BrowserDebugContext)?) {
        self.context = context
    }

    private var selectedVariant: BrowserImportHintVariant {
        BrowserImportHintVariant.resolved(from: variantRaw)
    }

    private var variantSelection: Binding<String> {
        Binding(
            get: { selectedVariant.rawValue },
            set: { variantRaw = BrowserImportHintVariant.resolved(from: $0).rawValue }
        )
    }

    private var showOnBlankTabsBinding: Binding<Bool> {
        Binding(
            get: { showOnBlankTabs },
            set: { newValue in
                showOnBlankTabs = newValue
                if newValue {
                    isDismissed = false
                }
            }
        )
    }

    private var presentation: BrowserImportHintPresentation {
        BrowserImportHintPresentation(
            variant: selectedVariant,
            showOnBlankTabs: showOnBlankTabs,
            isDismissed: isDismissed
        )
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Browser Import Hint")
                    .font(.headline)

                Text("Try lighter blank-tab import surfaces and dismissal states without touching the permanent Browser settings home.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                GroupBox("Variant") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Blank Tab Style", selection: variantSelection) {
                            ForEach(BrowserImportHintVariant.allCases) { variant in
                                Text(variant.title).tag(variant.rawValue)
                            }
                        }
                        .pickerStyle(.menu)

                        Text(selectedVariant.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 2)
                }

                GroupBox("State") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Show on blank browser tabs", isOn: showOnBlankTabsBinding)
                        Toggle("Pretend the user dismissed it", isOn: $isDismissed)

                        Text("Current blank-tab placement: \(presentation.blankTabPlacement.title)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Settings status: \(presentation.settingsStatus.title)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                }

                GroupBox("Quick Actions") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Button("Open Browser Settings") {
                                context?.presentBrowserPreferences()
                            }
                            Button("Open Import Dialog") {
                                context?.presentBrowserImportDialog()
                            }
                        }

                        Button("Reset Hint Debug State") {
                            context?.resetBrowserImportHintDebugState()
                        }
                    }
                    .padding(.top, 2)
                }

                GroupBox("Ideas") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Inline strip: default candidate, visible but quieter than the old floating card.")
                        Text("Floating card: strongest nudge, useful when we want more explanation.")
                        Text("Toolbar chip: most subtle, best when the hint should stay out of the content area.")
                        Text("Settings only: no in-browser nudge, Browser settings becomes the only permanent home.")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

#endif
