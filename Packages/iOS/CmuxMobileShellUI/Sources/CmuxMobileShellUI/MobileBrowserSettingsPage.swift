#if os(iOS)
import CmuxMobileBrowser
import CmuxMobileSupport
import SwiftUI

struct MobileBrowserSettingsPage: View {
    @Environment(MobileBrowserSettings.self) private var browserSettings

    var body: some View {
        @Bindable var browserSettings = browserSettings
        return Form {
            Section(L10n.string("mobile.settings.browser.search", defaultValue: "Search")) {
                Picker(selection: $browserSettings.defaultSearchEngine) {
                    ForEach(MobileBrowserSearchEngine.allCases, id: \.self) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                } label: {
                    Text(L10n.string("mobile.settings.browser.defaultSearchEngine", defaultValue: "Default Search Engine"))
                }
                .accessibilityIdentifier("MobileSettingsBrowserSearchEngine")
            }
        }
        .navigationTitle(L10n.string("mobile.settings.browser", defaultValue: "Browser"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("MobileSettingsBrowserPage")
    }
}
#endif
