import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI

/// The Dispatch sheet: work-order document at the root, project picker and
/// browse levels pushed on an in-sheet stack. Dismissing keeps the draft;
/// a successful dispatch clears it and hands control back to the shell, which
/// is already navigating into the new workspace's terminal.
struct DispatchComposerSheet: View {
    private enum Route: Hashable {
        case projectPicker
        case browse(String)
    }

    let service: any DispatchComposerServicing
    /// Called just before the launch request so the shell can arm its
    /// created-workspace navigation (mirrors the New Workspace flow).
    let willLaunch: () -> Void
    /// Called when a launch attempt is rejected, so the shell can disarm the
    /// created-workspace navigation it armed in `willLaunch`.
    let launchFailed: () -> Void
    /// Called once the DISPATCHED stamp has landed; the owner dismisses.
    let finished: () -> Void

    @State private var model: DispatchComposerModel
    @State private var picker: DispatchProjectPickerModel
    @State private var path: [Route] = []

    init(
        service: any DispatchComposerServicing,
        willLaunch: @escaping () -> Void,
        launchFailed: @escaping () -> Void,
        finished: @escaping () -> Void
    ) {
        self.service = service
        self.willLaunch = willLaunch
        self.launchFailed = launchFailed
        self.finished = finished
        _model = State(initialValue: DispatchComposerModel(service: service))
        _picker = State(initialValue: DispatchProjectPickerModel(service: service))
    }

    var body: some View {
        NavigationStack(path: $path) {
            DispatchDocumentScreen(
                model: model,
                openProjectPicker: { path.append(.projectPicker) },
                cancel: finished,
                finished: finished
            )
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .projectPicker:
                    DispatchProjectPickerScreen(
                        picker: picker,
                        composer: model,
                        select: selectDirectory,
                        browse: { path.append(.browse($0)) }
                    )
                case let .browse(directory):
                    DispatchBrowseScreen(
                        path: directory,
                        picker: picker,
                        composer: model,
                        select: selectDirectory,
                        browse: { path.append(.browse($0)) }
                    )
                }
            }
        }
        .onChange(of: model.launchState) { _, state in
            switch state {
            case .launching:
                willLaunch()
            case .rejected:
                launchFailed()
            case .idle, .dispatched:
                break
            }
        }
        .onDisappear {
            model.cancelInFlightWork()
            picker.cancelInFlightWork()
        }
        .accessibilityIdentifier("MobileDispatchComposer")
    }

    private func selectDirectory(_ directory: String) {
        model.selectDirectory(directory)
        path = []
    }
}
