#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextDesign
import Observation

/// The Density Lab's state (DEV builds, `debug.density_lab`): the five built-in densities as the lab
/// edits them, the one the app draws in now, and a capture of the main window at each density.
///
/// Every edit applies to the app at once (`DesignSettings.densityTokens`), so the real chrome is the
/// preview. Save writes every density to ``fileURL``; the next open reads it back, and the built-in
/// presets (`DensityPreset.tokens`) take the saved values when the result is harvested.
@MainActor @Observable
final class DensityLabModel {
    /// The metrics the lab exposes as exact tokens, with the slider range each may reach.
    static let metrics: [(tunable: MetricTunable, range: ClosedRange<Double>)] = [
        (MetricTunables.iconSize, 10...28),
        (MetricTunables.smallIconSize, 10...24),
        (MetricTunables.sidebarRowHeight, 16...48),
        (MetricTunables.sidebarRowHeightWithSubtitle, 28...72),
        (MetricTunables.sidebarHeaderHeight, 16...48),
        (MetricTunables.titlebarHeight, 24...64),
        (MetricTunables.tabStripHeight, 20...60),
        (MetricTunables.tabHeight, 16...52),
        (MetricTunables.controlHeight, 16...48),
        (MetricTunables.paletteRowHeight, 20...56),
        (MetricTunables.densityPaneCornerRadius, 0...20),
    ]

    /// Where Save writes and the lab reads on open.
    let fileURL: URL
    /// The five built-ins as the lab has them, densest first.
    private(set) var densities: [DensityTokens]
    /// The density the lab edits and the app draws in.
    private(set) var selectedID: String
    /// The main window at each density, by id (``captureAll()``).
    private(set) var captures: [String: CGImage] = [:]
    /// The backing scale of the captures (pixels per point), so they show at the size they ship at.
    private(set) var captureScale: CGFloat = 2
    /// An image to match, shown beside the captures at its own point size.
    var reference: CGImage?
    var referenceScale: CGFloat = 2
    /// The capture crop in points from the window's top-left: the sidebar and the tab strip.
    var cropWidth: Double = 640
    var cropHeight: Double = 360
    /// The last Save, Copy or capture result.
    private(set) var status = ""
    /// Whether ``captureAll()`` is running.
    private(set) var isCapturing = false

    private let design: DesignSettings
    private let targetWindow: @MainActor () -> NSWindow?
    private var recapture: Task<Void, Never>?

    /// - Parameters:
    ///   - design: The design settings the lab applies to.
    ///   - fileURL: Where Save writes (default `~/.config/cmux/density-lab.json`).
    ///   - targetWindow: The main window the captures read.
    init(design: DesignSettings = .shared, fileURL: URL? = nil, targetWindow: @escaping @MainActor () -> NSWindow?) {
        self.design = design
        self.targetWindow = targetWindow
        let url = fileURL ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/cmux/density-lab.json")
        self.fileURL = url
        let saved = Self.read(url)
        densities = DensityPreset.allCases.map { preset in saved.first { $0.id == preset.rawValue } ?? preset.tokens }
        let current = design.densityTokens.id
        selectedID = DensityPreset(rawValue: current) != nil ? current : DensityPreset.cozy.rawValue
    }

    /// The density the lab edits.
    var selected: DensityTokens {
        get { densities.first { $0.id == selectedID } ?? DensityPreset.cozy.tokens }
        set {
            guard let index = densities.firstIndex(where: { $0.id == newValue.id }) else { return }
            densities[index] = newValue
            design.densityTokens = newValue
            scheduleRecapture()
        }
    }

    /// Whether the selected density differs from its built-in.
    var selectedIsEdited: Bool { DensityPreset(rawValue: selectedID).map { $0.tokens != selected } ?? false }

    /// Applies the lab's version of the density `id` to the app.
    func select(_ id: String) {
        guard densities.contains(where: { $0.id == id }) else { return }
        selectedID = id
        design.densityTokens = selected
        scheduleRecapture()
    }

    /// Puts the selected density back to its built-in values.
    func resetSelected() {
        guard let preset = DensityPreset(rawValue: selectedID) else { return }
        selected = preset.tokens
    }

    /// The value a metric draws at the selected density: its exact token, else the level's.
    func resolved(_ tunable: MetricTunable) -> Double {
        let density = selected
        let value = tunable.glyph
            ? density.resolveGlyph(compact: tunable.compact, comfortable: tunable.comfortable, token: tunable.name)
            : density.resolve(compact: tunable.compact, comfortable: tunable.comfortable, token: tunable.name)
        return Double(value)
    }

    /// Sets (or with nil, clears) the selected density's exact `token`.
    func setToken(_ name: String, _ value: Double?) {
        var density = selected
        density.tokens[name] = value.map { $0.rounded() }
        selected = density
    }

    // MARK: Save and export

    /// Writes every density to ``fileURL`` as `{"densities": [DensityTokens]}`.
    func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(DensityLabFile(densities: densities))
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            status = "Saved \(fileURL.path)"
        } catch {
            status = "Save failed: \(error.localizedDescription)"
        }
    }

    /// Copies the `DensityPreset.tokens` switch that ships the lab's values.
    func copySwift() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(DensityLabExport.swift(densities), forType: .string)
        status = "Copied the DensityPreset.tokens switch"
    }

    private static func read(_ url: URL) -> [DensityTokens] {
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(DensityLabFile.self, from: data) else { return [] }
        return file.densities.map {
            DensityTokens(id: $0.id, name: $0.name, basedOn: $0.basedOn, level: $0.level, spacing: $0.spacing,
                          fontSize: $0.fontSize, tokens: $0.tokens)
        }
    }

    // MARK: Captures

    /// Draws the main window at every density in turn and keeps a capture of each, then goes back
    /// to the selected density.
    func captureAll() async {
        guard !isCapturing, let window = targetWindow() else {
            if targetWindow() == nil { status = "No main window to capture" }
            return
        }
        recapture?.cancel()
        isCapturing = true
        defer { isCapturing = false }
        for density in densities {
            design.densityTokens = density
            if let image = await Self.capture(window) { captures[density.id] = image }
        }
        captureScale = window.backingScaleFactor
        design.densityTokens = selected
        status = "Captured \(captures.count) densities"
    }

    /// Captures the selected density again after an edit; a newer edit cancels an older capture.
    private func scheduleRecapture() {
        guard !isCapturing, let window = targetWindow() else { return }
        recapture?.cancel()
        let id = selectedID
        recapture = Task { [weak self] in
            guard let image = await Self.capture(window), !Task.isCancelled, let self else { return }
            captures[id] = image
            captureScale = window.backingScaleFactor
        }
    }

    /// The window as the window server composites it once the density change has laid out and drawn.
    /// Observation hosts apply a density change on the main actor's next turns, so the capture yields
    /// to them first and then forces the layout and display the change scheduled.
    private static func capture(_ window: NSWindow) async -> CGImage? {
        for _ in 0..<3 { await Task.yield() }
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        if let composited = await window.compositedImageWithOverlays() { return composited.image }
        return try? window.snapshotImage().image
    }
}

/// What Save writes.
struct DensityLabFile: Codable {
    var densities: [DensityTokens]
}
#endif
