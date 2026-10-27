#if CMUX_UI_LAYER_PREVIEW
public import SwiftUI
import CmuxNextDesign
import CmuxNextIcons

/// Read-only sample data for the Debug UI-layer host.
///
/// The host owns the projection adapter. This type keeps the real cmux NEXT
/// SwiftUI view independent from daemon models and therefore cheap to rebuild.
public struct UiLayerPreviewData: Sendable {
    public var workspaceName: String
    public var tabTitle: String
    public var tabSubtitle: String?
    public var composerPlaceholder: String

    public init(
        workspaceName: String,
        tabTitle: String,
        tabSubtitle: String? = nil,
        composerPlaceholder: String = "Write a message…"
    ) {
        self.workspaceName = workspaceName
        self.tabTitle = tabTitle
        self.tabSubtitle = tabSubtitle
        self.composerPlaceholder = composerPlaceholder
    }
}

/// The real cmux NEXT preview surface used by `Prototypes/UiLayerHost`.
///
/// This intentionally uses production SwiftUI primitives from CmuxNextDesign
/// and CmuxNextIcons. It has no action sink, daemon connection, or app state;
/// the button is present for layout only and its action is a no-op.
public struct UiLayerPreviewView: View {
    private let data: UiLayerPreviewData

    public init(data: UiLayerPreviewData) {
        self.data = data
    }

    public var body: some View {
        HStack(spacing: 0) {
            sidebar
            HairlineDivider(.vertical, color: .secondary.opacity(0.2))
            VStack(spacing: 0) {
                tabBar
                HairlineDivider(color: .secondary.opacity(0.2))
                pane
                composer
            }
        }
        .background(.windowBackground)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: Metrics.space3) {
            Text("WORKSPACES")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: Metrics.space2) {
                Icon(symbol: "rectangle.3.group", size: 14)
                Text(data.workspaceName).lineLimit(1)
                Spacer()
                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
            }
            .padding(.horizontal, Metrics.space2)
            .padding(.vertical, Metrics.space2)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Spacer()
            Text("REAL CMUX NEXT VIEW")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(Metrics.space4)
        .frame(width: 220)
    }

    private var tabBar: some View {
        HStack(spacing: Metrics.space2) {
            Icon(symbol: "terminal", size: 13)
            Text(data.tabTitle).lineLimit(1)
            if let subtitle = data.tabSubtitle {
                Text(subtitle).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Icon(symbol: "plus", size: 14).foregroundStyle(.secondary)
        }
        .padding(.horizontal, Metrics.space4)
        .padding(.vertical, Metrics.space3)
    }

    private var pane: some View {
        VStack(alignment: .leading, spacing: Metrics.space3) {
            Text(data.workspaceName).font(.title3.weight(.medium))
            Text("Native preview host · read-only sample data")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(Metrics.space6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var composer: some View {
        HStack(spacing: Metrics.space3) {
            Icon(symbol: "paperclip", size: 14).foregroundStyle(.secondary)
            Text(data.composerPlaceholder).foregroundStyle(.tertiary)
            Spacer()
            CmuxDialogActionButton("Send", hint: .return) {}
                .buttonStyle(.borderless)
                .disabled(true)
        }
        .padding(Metrics.space3)
        .background(.bar)
    }
}
#endif
