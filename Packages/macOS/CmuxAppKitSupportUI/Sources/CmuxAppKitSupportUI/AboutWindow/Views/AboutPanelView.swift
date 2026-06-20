#if canImport(AppKit)

internal import SwiftUI

/// The contents of the "About cmux" window: the app icon, name, description,
/// version/build/commit rows, the Docs/GitHub/Licenses buttons, and the
/// copyright notice.
///
/// Version, build, commit, and copyright are read from `Bundle.main` (the
/// running app bundle, correct from any module). All user-facing labels are
/// injected via ``AboutPanelStrings`` because they are localized and must
/// resolve against the app bundle's catalog rather than this package's bundle.
/// The Licenses button invokes the injected ``showAcknowledgments`` closure,
/// which the coordinator wires to its package-owned Acknowledgments window so
/// the former `AcknowledgmentsWindowController.shared` singleton can be retired.
struct AboutPanelView: View {
    @Environment(\.openURL) private var openURL

    private let strings: AboutPanelStrings
    private let showAcknowledgments: @MainActor () -> Void

    private let githubURL = URL(string: "https://github.com/manaflow-ai/cmux")
    private let docsURL = URL(string: "https://cmux.com/docs")

    /// Creates the About panel.
    ///
    /// - Parameters:
    ///   - strings: Localized labels resolved against the app bundle.
    ///   - showAcknowledgments: Presents the Acknowledgments (Third-Party
    ///     Licenses) window.
    init(strings: AboutPanelStrings, showAcknowledgments: @escaping @MainActor () -> Void) {
        self.strings = strings
        self.showAcknowledgments = showAcknowledgments
    }

    private var version: String? { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String }
    private var build: String? { Bundle.main.infoDictionary?["CFBundleVersion"] as? String }
    private var commit: String? {
        if let value = Bundle.main.infoDictionary?["CMUXCommit"] as? String, !value.isEmpty {
            return value
        }
        let env = ProcessInfo.processInfo.environment["CMUX_COMMIT"] ?? ""
        return env.isEmpty ? nil : env
    }
    private var copyright: String? { Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String }

    var body: some View {
        VStack(alignment: .center) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .renderingMode(.original)
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 3)

            VStack(alignment: .center, spacing: 32) {
                VStack(alignment: .center, spacing: 8) {
                    Text(strings.appName)
                        .bold()
                        .font(.title)
                    Text(strings.description)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .font(.caption)
                        .tint(.secondary)
                        .opacity(0.8)
                }
                .textSelection(.enabled)

                VStack(spacing: 2) {
                    if let version {
                        AboutPropertyRow(label: strings.versionLabel, text: version)
                    }
                    if let build {
                        AboutPropertyRow(label: strings.buildLabel, text: build)
                    }
                    let commitText = commit ?? "—"
                    let commitURL = commit.flatMap { hash in
                        URL(string: "https://github.com/manaflow-ai/cmux/commit/\(hash)")
                    }
                    AboutPropertyRow(label: strings.commitLabel, text: commitText, url: commitURL)
                }
                .frame(maxWidth: .infinity)

                HStack(spacing: 8) {
                    if let url = docsURL {
                        Button(strings.docs) {
                            openURL(url)
                        }
                    }
                    if let url = githubURL {
                        Button(strings.github) {
                            openURL(url)
                        }
                    }
                    Button(strings.licenses) {
                        showAcknowledgments()
                    }
                }

                if let copy = copyright, !copy.isEmpty {
                    Text(copy)
                        .font(.caption)
                        .textSelection(.enabled)
                        .tint(.secondary)
                        .opacity(0.8)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 8)
        .padding(32)
        .frame(minWidth: 280)
        .background(AboutVisualEffectBackground(material: .underWindowBackground).ignoresSafeArea())
    }
}

#endif
