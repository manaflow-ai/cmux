public import SwiftUI
public import CmuxUpdater
import AVKit
import CmuxFoundation
import Observation

/// What the What's New recap is showing.
@MainActor
@Observable
public final class WhatsNewViewModel {
    public enum Phase: Equatable {
        case loading
        case loaded([WhatsNewRelease])
        case failed
    }

    public var phase: Phase
    /// The `app.whatsNew` choice shown in the footer picker.
    public var selectedModeID: String

    public init(phase: Phase = .loading, selectedModeID: String) {
        self.phase = phase
        self.selectedModeID = selectedModeID
    }
}

/// One choice in the footer's "After updates" picker.
public struct WhatsNewModeOption: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// Callbacks the host provides.
public struct WhatsNewViewActions {
    public var openURL: (URL) -> Void
    public var retry: () -> Void
    public var selectMode: (String) -> Void
    public var done: () -> Void

    public init(
        openURL: @escaping (URL) -> Void,
        retry: @escaping () -> Void,
        selectMode: @escaping (String) -> Void,
        done: @escaping () -> Void
    ) {
        self.openURL = openURL
        self.retry = retry
        self.selectMode = selectMode
        self.done = done
    }
}

/// The What's New recap: each release's highlights with a "Try it" hint,
/// media when the release has it, and a link to the full changelog.
public struct WhatsNewView: View {
    private let model: WhatsNewViewModel
    private let modeOptions: [WhatsNewModeOption]
    private let actions: WhatsNewViewActions

    public init(model: WhatsNewViewModel, modeOptions: [WhatsNewModeOption], actions: WhatsNewViewActions) {
        self.model = model
        self.modeOptions = modeOptions
        self.actions = actions
    }

    public var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 560, height: 620)
        .cmuxFontMagnificationEnvironment()
        .accessibilityIdentifier("WhatsNewView")
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView()
                .controlSize(.small)
        case .failed:
            VStack(spacing: 10) {
                Text(String(localized: "whatsNew.failed", defaultValue: "Couldn't load what's new."))
                    .cmuxFont(size: 13, weight: .medium)
                HStack(spacing: 8) {
                    Button(String(localized: "whatsNew.retry", defaultValue: "Try Again")) {
                        actions.retry()
                    }
                    Button(String(localized: "whatsNew.openChangelog", defaultValue: "Open Changelog")) {
                        actions.openURL(WhatsNewCatalog.changelogPage)
                    }
                }
                .controlSize(.small)
            }
        case .loaded(let releases):
            if releases.isEmpty {
                VStack(spacing: 10) {
                    Text(String(localized: "whatsNew.empty", defaultValue: "No highlights for this version yet."))
                        .cmuxFont(size: 13, weight: .medium)
                    Button(String(localized: "whatsNew.openChangelog", defaultValue: "Open Changelog")) {
                        actions.openURL(WhatsNewCatalog.changelogPage)
                    }
                    .controlSize(.small)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        Text(String(localized: "whatsNew.title", defaultValue: "What's New in cmux"))
                            .cmuxFont(size: 22, weight: .bold)
                        ForEach(releases) { release in
                            WhatsNewReleaseSection(release: release, openURL: actions.openURL)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(String(localized: "whatsNew.afterUpdates", defaultValue: "After updates:"))
                .cmuxFont(size: 11)
                .foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { model.selectedModeID },
                set: { newValue in
                    model.selectedModeID = newValue
                    actions.selectMode(newValue)
                }
            )) {
                ForEach(modeOptions) { option in
                    Text(option.title).tag(option.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .controlSize(.small)
            .accessibilityIdentifier("WhatsNewModePicker")
            Spacer(minLength: 0)
            Button(String(localized: "whatsNew.done", defaultValue: "Done")) {
                actions.done()
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.small)
            .accessibilityIdentifier("WhatsNewDoneButton")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct WhatsNewReleaseSection: View {
    let release: WhatsNewRelease
    let openURL: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                // Product name and version number: invariant across languages.
                Text(verbatim: "cmux \(release.version)")
                    .cmuxFont(size: 11, weight: .semibold)
                    .foregroundStyle(.secondary)
                Text(release.title)
                    .cmuxFont(size: 15, weight: .semibold)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let hero = release.hero {
                WhatsNewImage(url: hero)
            }
            ForEach(release.features) { feature in
                WhatsNewFeatureCard(feature: feature)
            }
            Button {
                openURL(release.url ?? WhatsNewCatalog.changelogPage)
            } label: {
                HStack(spacing: 4) {
                    Text(String(localized: "whatsNew.fullChangelog", defaultValue: "Read the full changelog"))
                    Image(systemName: "arrow.up.right")
                        .cmuxFont(size: 9)
                }
                .cmuxFont(size: 12, weight: .medium)
            }
            .buttonStyle(.link)
        }
    }
}

private struct WhatsNewFeatureCard: View {
    let feature: WhatsNewRelease.Feature

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(feature.title)
                .cmuxFont(size: 13, weight: .semibold)
            Text(feature.description)
                .cmuxFont(size: 12)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let tryIt = feature.tryIt {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(String(localized: "whatsNew.tryIt", defaultValue: "Try it"))
                        .cmuxFont(size: 11, weight: .semibold)
                        .foregroundStyle(Color.accentColor)
                    Text(tryIt)
                        .cmuxFont(size: 12)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            if let video = feature.video {
                WhatsNewVideo(url: video)
            } else if let image = feature.image {
                WhatsNewImage(url: image)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

private struct WhatsNewImage: View {
    let url: URL

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            case .failure:
                EmptyView()
            default:
                Color.secondary.opacity(0.08)
                    .frame(height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 260)
        .accessibilityHidden(true)
    }
}

private struct WhatsNewVideo: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
            } else {
                Color.secondary.opacity(0.08)
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onAppear {
            if player == nil {
                let player = AVPlayer(url: url)
                player.isMuted = true
                self.player = player
            }
        }
        .onDisappear {
            player?.pause()
        }
    }
}
