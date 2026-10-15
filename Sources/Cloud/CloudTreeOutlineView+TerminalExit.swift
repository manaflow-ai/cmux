import AppKit
import CmuxFoundation
import CmuxSurfaceCatalogModel
import SwiftUI

extension CloudTreeOutlineView.Coordinator {
    /// A failed run's row has no pane to open: its click shows how it ended,
    /// its last lines, and the fix when one is recognized. Anchored like the
    /// CodeRouter guide, to the row's cell, opening toward the content.
    func showTerminalExitDetails(_ node: CloudTreeNode, row: CloudTreeTerminalRow) {
        guard let failure = row.exitFailure,
              let outlineView,
              let index = (0..<outlineView.numberOfRows).first(where: { (outlineView.item(atRow: $0) as? CloudTreeNode)?.id == node.id }),
              let cell = outlineView.view(atColumn: 0, row: index, makeIfNecessary: false) else { return }
        guidePopover?.close()
        let model = CloudTerminalExitDetailsModel(title: row.displayTitle, failure: failure)
        let actions = nodeActions
        let resource = row.resource
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: CloudTerminalExitDetailsView(model: model, onFix: { [weak self, weak popover] diagnosis in
                popover?.close()
                self?.guidePopover = nil
                switch diagnosis {
                case .missingAPIKey: actions.addAPIKey(resource.machine)
                }
            })
        )
        popover.show(relativeTo: cell.bounds, of: cell, preferredEdge: .minX)
        guidePopover = popover
        model.load { await actions.readTerminalExitOutput(resource) }
    }
}

/// View state for a failed run's details: the output arrives after the
/// popover opens, so the headline shows at once and the lines fill in.
@MainActor
final class CloudTerminalExitDetailsModel: ObservableObject {
    let title: String
    let failure: CloudTerminalExitPresentation
    @Published private(set) var lastLines: String?
    @Published private(set) var isLoading = false
    @Published private(set) var diagnosis: CloudTerminalExitPresentation.Diagnosis?
    private var loadTask: Task<Void, Never>?

    init(title: String, failure: CloudTerminalExitPresentation) {
        self.title = title
        self.failure = failure
    }

    func load(_ read: @escaping @MainActor () async -> String?) {
        loadTask?.cancel()
        isLoading = true
        loadTask = Task { [weak self] in
            let text = await read()
            guard !Task.isCancelled, let self else { return }
            self.apply(output: text)
        }
    }

    func apply(output: String?) {
        isLoading = false
        let lines = output.map { CloudTerminalExitPresentation.lastLines(of: $0) } ?? ""
        lastLines = lines.isEmpty ? nil : lines
        diagnosis = lastLines.flatMap(CloudTerminalExitPresentation.diagnosis(lastLines:))
    }
}

struct CloudTerminalExitDetailsView: View {
    @ObservedObject var model: CloudTerminalExitDetailsModel
    let onFix: @MainActor (CloudTerminalExitPresentation.Diagnosis) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(CloudTreeIconPalette.attention)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.failure.headline)
                        .cmuxFont(size: 13, weight: .semibold)
                    Text(model.title)
                        .cmuxFont(size: 11)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if let diagnosis = model.diagnosis {
                Text(CloudTerminalExitPresentation.diagnosisExplanation(diagnosis))
                    .cmuxFont(size: 12)
                    .fixedSize(horizontal: false, vertical: true)
            }
            lastLinesBlock
            if let diagnosis = model.diagnosis {
                HStack {
                    Spacer()
                    Button(CloudTerminalExitPresentation.fixTitle(diagnosis)) { onFix(diagnosis) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(14)
        .frame(width: 380, alignment: .leading)
    }

    @ViewBuilder
    private var lastLinesBlock: some View {
        if let lines = model.lastLines {
            ScrollView {
                Text(lines)
                    .cmuxFont(size: 11, design: .monospaced)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 180)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
        } else if model.isLoading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(String(localized: "cloudTree.terminal.exit.loading", defaultValue: "Reading its last lines\u{2026}"))
                    .cmuxFont(size: 11)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(String(localized: "cloudTree.terminal.exit.noOutput", defaultValue: "Its output is no longer available."))
                .cmuxFont(size: 11)
                .foregroundStyle(.secondary)
        }
    }
}
