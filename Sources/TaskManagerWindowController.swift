import AppKit
import Combine
import SwiftUI

@MainActor
final class TaskManagerWindowController: NSWindowController, NSWindowDelegate {
    static let shared = TaskManagerWindowController()

    private let model = CmuxTaskManagerModel()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.taskManager")
        window.title = String(localized: "taskManager.windowTitle", defaultValue: "Task Manager")
        window.center()
        window.contentView = NSHostingView(rootView: CmuxTaskManagerView(model: model))
        AppDelegate.shared?.applyWindowDecorations(to: window)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else { return }
        if !window.isVisible {
            window.center()
        }
        model.start()
        NSApp.unhide(nil)
        window.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
    }

    func windowWillClose(_ notification: Notification) {
        model.stop()
    }
}

@MainActor
private final class CmuxTaskManagerModel: ObservableObject {
    @Published private(set) var snapshot = CmuxTaskManagerSnapshot.empty
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published var includesProcesses = false {
        didSet {
            guard oldValue != includesProcesses else { return }
            refresh(force: true)
        }
    }

    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private let refreshInterval: TimeInterval = 3.0

    func start() {
        guard refreshTimer == nil else {
            refresh(force: true)
            return
        }
        refresh(force: true)
        let timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        timer.tolerance = 0.75
        refreshTimer = timer
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
    }

    func refresh(force: Bool = false) {
        if refreshTask != nil {
            guard force else { return }
            refreshTask?.cancel()
            refreshTask = nil
        }

        let includeProcesses = includesProcesses
        isRefreshing = true
        refreshTask = Task { [weak self] in
            do {
                let payload = try await TerminalController.shared.taskManagerTopPayload(includeProcesses: includeProcesses)
                guard !Task.isCancelled else { return }
                let snapshot = CmuxTaskManagerSnapshot(payload: payload)
                self?.snapshot = snapshot
                self?.errorMessage = nil
            } catch {
                guard !Task.isCancelled else { return }
                self?.errorMessage = String(describing: error)
            }
            self?.isRefreshing = false
            self?.refreshTask = nil
        }
    }
}

private struct CmuxTaskManagerView: View {
    @ObservedObject var model: CmuxTaskManagerModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            summary
            Divider()
            tableHeader
            Divider()
            tableBody
        }
        .frame(minWidth: 820, minHeight: 480)
        .onAppear {
            model.start()
        }
        .onDisappear {
            model.stop()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text(String(localized: "taskManager.title", defaultValue: "Task Manager"))
                .font(.title3.weight(.semibold))

            if model.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(String(localized: "taskManager.refreshing", defaultValue: "Refreshing"))
            }

            Spacer()

            Toggle(
                String(localized: "taskManager.showProcesses", defaultValue: "Processes"),
                isOn: $model.includesProcesses
            )
            .toggleStyle(.checkbox)

            Button {
                model.refresh(force: true)
            } label: {
                Label(String(localized: "taskManager.refresh", defaultValue: "Refresh"), systemImage: "arrow.clockwise")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var summary: some View {
        HStack(spacing: 24) {
            metric(
                title: String(localized: "taskManager.summary.cpu", defaultValue: "CPU"),
                value: CmuxTaskManagerFormat.cpu(model.snapshot.total.cpuPercent)
            )
            metric(
                title: String(localized: "taskManager.summary.memory", defaultValue: "Memory"),
                value: CmuxTaskManagerFormat.bytes(model.snapshot.total.residentBytes)
            )
            metric(
                title: String(localized: "taskManager.summary.processes", defaultValue: "Processes"),
                value: "\(model.snapshot.total.processCount)"
            )
            metric(
                title: String(localized: "taskManager.summary.updated", defaultValue: "Updated"),
                value: model.snapshot.updatedText
            )
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func metric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .monospacedDigit()
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 8) {
            Text(String(localized: "taskManager.column.name", defaultValue: "Name"))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(String(localized: "taskManager.column.cpu", defaultValue: "CPU"))
                .frame(width: 82, alignment: .trailing)
            Text(String(localized: "taskManager.column.memory", defaultValue: "Memory"))
                .frame(width: 96, alignment: .trailing)
            Text(String(localized: "taskManager.column.processes", defaultValue: "Proc"))
                .frame(width: 58, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private var tableBody: some View {
        if let errorMessage = model.errorMessage {
            CmuxTaskManagerMessageView(
                title: String(localized: "taskManager.error.title", defaultValue: "Unable to load resource usage"),
                detail: errorMessage
            )
        } else if model.snapshot.rows.isEmpty {
            CmuxTaskManagerMessageView(
                title: String(localized: "taskManager.empty.title", defaultValue: "No resource usage"),
                detail: String(localized: "taskManager.empty.detail", defaultValue: "Open a workspace, terminal, or browser surface to see it here.")
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.snapshot.rows) { row in
                        CmuxTaskManagerRowView(row: row)
                        Divider()
                            .padding(.leading, 16)
                    }
                }
            }
        }
    }
}

private struct CmuxTaskManagerMessageView: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

private struct CmuxTaskManagerRowView: View {
    let row: CmuxTaskManagerRow

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Color.clear
                    .frame(width: CGFloat(row.level) * 14)
                Image(systemName: row.kind.systemImage)
                    .foregroundStyle(row.kind.tint)
                    .font(.system(size: 12))
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.title)
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                    if !row.detail.isEmpty {
                        Text(row.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(CmuxTaskManagerFormat.cpu(row.resources.cpuPercent))
                .frame(width: 82, alignment: .trailing)
            Text(CmuxTaskManagerFormat.bytes(row.resources.residentBytes))
                .frame(width: 96, alignment: .trailing)
            Text("\(row.resources.processCount)")
                .frame(width: 58, alignment: .trailing)
        }
        .font(.system(size: 12.5, design: .default))
        .monospacedDigit()
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
        .opacity(row.isDimmed ? 0.68 : 1)
    }
}
