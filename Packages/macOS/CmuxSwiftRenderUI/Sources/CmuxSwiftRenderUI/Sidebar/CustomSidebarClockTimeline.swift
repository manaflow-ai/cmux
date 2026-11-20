import CmuxSwiftRender
import SwiftUI

/// Drives a custom sidebar's `clock` and ticks only for sidebars that read it.
///
/// Wrap the sidebar surface in this view instead of a fixed one-second
/// `TimelineView`. While the sidebar's source mentions `clock`, the content
/// closure runs at every whole second; otherwise it runs once with the mount
/// time and again only when the host's own inputs change. A sidebar that never
/// reads the clock therefore re-renders only when its data changes.
///
/// The source is read through a ``CustomSidebarModel`` (same name resolution,
/// file watching and reload requests as the renderer), so adding `clock` to a
/// sidebar file starts the tick on save, and removing it stops the tick.
/// `sourceOverride` (an in-memory preview) is checked directly.
public struct CustomSidebarClockTimeline<Content: View>: View {
    @State private var model: CustomSidebarModel
    private let fileURL: URL
    private let sourceOverride: String?
    private let content: (Date) -> Content

    /// Creates the timeline for one sidebar.
    ///
    /// - Parameters:
    ///   - fileURL: The sidebar file the surface renders.
    ///   - sourceOverride: In-memory source that replaces the file, if any.
    ///   - content: Builds the surface for a clock date.
    public init(
        fileURL: URL,
        sourceOverride: String? = nil,
        @ViewBuilder content: @escaping (Date) -> Content
    ) {
        _model = State(initialValue: CustomSidebarModel(fileURL: fileURL))
        self.fileURL = fileURL
        self.sourceOverride = sourceOverride
        self.content = content
    }

    public var body: some View {
        TimelineView(CustomSidebarClockSchedule(ticksEverySecond: ticksEverySecond)) { timeline in
            content(timeline.date)
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .onChange(of: fileURL) { _, newURL in
            // Follow provider switches without remounting the surface: the
            // remote renderer keeps its worker across a switch on purpose.
            model.stop()
            let next = CustomSidebarModel(fileURL: newURL)
            model = next
            next.start()
        }
    }

    private var ticksEverySecond: Bool {
        if let sourceOverride {
            return CustomSidebarClock.sourceReadsClock(sourceOverride)
        }
        return Self.ticksEverySecond(for: model.state)
    }

    /// Whether a loaded sidebar state needs the one-second clock tick.
    ///
    /// JSON sidebars never see the data context, and missing or broken files
    /// render nothing that could read it.
    static func ticksEverySecond(for state: CustomSidebarModel.State) -> Bool {
        switch state {
        case let .swiftSource(source), let .jsSource(source):
            return CustomSidebarClock.sourceReadsClock(source)
        case .json, .missing, .failed:
            return false
        }
    }
}

/// A timeline that either ticks at every whole second or never after its
/// first entry.
struct CustomSidebarClockSchedule: TimelineSchedule, Equatable {
    let ticksEverySecond: Bool

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(startDate: startDate, ticksEverySecond: ticksEverySecond)
    }

    struct Entries: Sequence, IteratorProtocol {
        private var upcoming: Date?
        private let ticksEverySecond: Bool

        init(startDate: Date, ticksEverySecond: Bool) {
            upcoming = startDate
            self.ticksEverySecond = ticksEverySecond
        }

        mutating func next() -> Date? {
            guard let current = upcoming else { return nil }
            if ticksEverySecond {
                // Land later ticks on whole seconds so `clock.second` steps
                // exactly once per entry.
                let seconds = current.timeIntervalSinceReferenceDate.rounded(.down) + 1
                upcoming = Date(timeIntervalSinceReferenceDate: seconds)
            } else {
                upcoming = nil
            }
            return current
        }
    }
}
