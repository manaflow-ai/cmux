#if os(iOS)
import CmuxMobileSupport
import SwiftUI
@preconcurrency import UIKit

/// Native chrome and error/loading states around the bundled Pierre diff app.
struct MobileDiffScreen: View {
    let model: MobileDiffViewerModel
    let snapshot: MobileDiffStatusSnapshot
    let workspaceTitle: String
    let initialPath: String
    let back: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var controller: MobileDiffWebViewController
    @State private var isTreePresented = false

    init(
        model: MobileDiffViewerModel,
        snapshot: MobileDiffStatusSnapshot,
        workspaceTitle: String,
        initialPath: String,
        back: @escaping () -> Void
    ) {
        self.model = model
        self.snapshot = snapshot
        self.workspaceTitle = workspaceTitle
        self.initialPath = initialPath
        self.back = back
        let index = snapshot.files.firstIndex(where: { $0.path == initialPath }) ?? 0
        _controller = State(initialValue: MobileDiffWebViewController(
            initialPath: initialPath,
            initialIndex: index,
            total: snapshot.files.count
        ))
    }

    var body: some View {
        GeometryReader { geometry in
            let layout: MobileDiffHostPage.Layout = geometry.size.width > geometry.size.height
                ? .split
                : .unified
            VStack(spacing: 0) {
                MobileDiffHeaderView(
                    path: controller.currentPath,
                    index: controller.currentIndex,
                    total: controller.total,
                    back: back,
                    openTree: openTree,
                    previous: controller.previousFile,
                    next: controller.nextFile
                )
                Divider()
                ZStack {
                    Color(uiColor: .systemBackground)
                    MobileDiffWebView(
                        controller: controller,
                        service: model.service,
                        files: snapshot.files,
                        layout: layout,
                        theme: colorScheme,
                        title: workspaceTitle,
                        onTooLargePaths: model.markTooLarge,
                        onPartialFailure: model.markPartialDiffFailure
                    )
                    if let errorMessage = controller.errorMessage {
                        diffError(errorMessage)
                    }
                    if let message = model.partialDiffErrorMessage {
                        partialDiffError(message)
                    }
                }
                .overlay(alignment: .top) {
                    if !controller.isReady, controller.errorMessage == nil {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .accessibilityLabel(
                                L10n.string("mobile.diff.loadingDiff", defaultValue: "Loading diff…")
                            )
                    }
                }
            }
            .background(Color(uiColor: .systemBackground))
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $isTreePresented) {
            treeSheet
        }
    }

    private var treeSheet: some View {
        NavigationStack {
            MobileDiffTreeView(
                snapshot: snapshot,
                collapsedDirectories: model.collapsedDirectories,
                tooLargePaths: model.tooLargePaths,
                selectedPath: controller.currentPath,
                toggleDirectory: model.toggleDirectory,
                selectFile: selectFromTree
            )
            .navigationTitle(L10n.string("mobile.diff.changedFiles", defaultValue: "Changed files"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.diff.done", defaultValue: "Done")) {
                        isTreePresented = false
                    }
                }
            }
        }
    }

    private func openTree() {
        model.expandDirectories(containing: controller.currentPath)
        isTreePresented = true
    }

    private func selectFromTree(_ path: String) {
        let index = snapshot.files.firstIndex(where: { $0.path == path }) ?? 0
        controller.requestScroll(path: path, index: index, total: snapshot.files.count)
        isTreePresented = false
    }

    private func diffError(_ message: String) -> some View {
        ContentUnavailableView {
            Label(
                L10n.string("mobile.diff.unavailable", defaultValue: "Changes unavailable"),
                systemImage: "exclamationmark.triangle"
            )
        } description: {
            Text(message)
        } actions: {
            Button(L10n.string("mobile.diff.retry", defaultValue: "Retry")) {
                controller.reload()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }

    private func partialDiffError(_ message: String) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                Text(message)
                    .font(.subheadline)
                Spacer(minLength: 8)
                Button(L10n.string("mobile.diff.retry", defaultValue: "Retry")) {
                    model.clearPartialDiffFailure()
                    controller.reload()
                }
                .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding()
        }
    }
}
#endif
