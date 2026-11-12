public import AppKit
public import CmuxNextDesign
import CmuxNextCompat
import CmuxNextSettings
import CmuxNextWakeups
import ImageIO
import Observation

/// What the Density Lab needs from the app: the main window it captures and the cmux.json write for custom densities.
public struct DensityLabHooks {
    /// The main window the captures read.
    public var targetWindow: @MainActor () -> NSWindow?
    /// Writes `appearance.customDensities` and, when given, selects the custom density with that id.
    public var saveCustom: @MainActor (_ densities: [DensityTokens], _ use: String?) -> Void

    public init(targetWindow: @escaping @MainActor () -> NSWindow?, saveCustom: @escaping @MainActor ([DensityTokens], String?) -> Void) {
        self.targetWindow = targetWindow
        self.saveCustom = saveCustom
    }
}

/// The Density Lab's state (DEV and NIGHTLY, `debug.densityLab`): every density the app has, the one the app draws in
/// now, and a capture of the main window at each.
///
/// Every edit applies to the app at once (`DesignSettings.densityTokens`), so the real window is the preview. A custom
/// density's edits are saved to cmux.json when a slider is let go. A built-in's edits stay in the lab until Save writes
/// them to ``fileURL`` for the team to ship (Copy as preset code gives the `DensityPreset.tokens` switch), or until
/// Save as custom density keeps them as the person's own.
@MainActor @Observable
public final class DensityLabModel {
    /// Where Save writes the built-ins and the lab reads them back.
    public let fileURL: URL
    /// The five built-ins as the lab has them, densest first.
    private(set) var builtIns: [DensityTokens]
    /// The person's custom densities (`appearance.customDensities`), as the lab has them.
    private(set) var customs: [DensityTokens]
    /// The density the lab edits and the app draws in.
    private(set) var selectedID: String
    /// The main window at each density, by id (``captureAll()``).
    private(set) var captures: [String: CGImage] = [:]
    /// The captures' backing scale (pixels per point), so they show at the size they ship at.
    private(set) var captureScale: CGFloat = 2
    /// An image to match, shown above the captures at its own point size.
    var reference: CGImage?
    var referenceScale: CGFloat = 2
    /// How much of the window each capture shows, in points from its top-left (the sidebar and the tabs).
    var cropWidth: Double = 560
    var cropHeight: Double = 300
    /// The last action's result, for the status line.
    private(set) var status = ""
    private(set) var isCapturing = false

    @ObservationIgnored private let design: DesignSettings
    @ObservationIgnored private let hooks: DensityLabHooks
    @ObservationIgnored private var recapture: Task<Void, Never>?

    public init(design: DesignSettings = .shared, fileURL: URL? = nil, hooks: DensityLabHooks) {
        self.design = design
        self.hooks = hooks
        self.fileURL = fileURL ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/cmux/density-lab.json")
        builtIns = DensityPreset.allCases.map(\.tokens)
        customs = design.customDensities
        selectedID = design.densityTokens.id
    }

    // MARK: Reading

    /// Every density, built-ins first.
    var all: [DensityTokens] { builtIns + customs }

    /// The density the lab edits.
    var selected: DensityTokens { all.first { $0.id == selectedID } ?? design.densityTokens }

    var selectedIsBuiltIn: Bool { DensityPreset(rawValue: selectedID) != nil }

    /// What the selected density's Reset goes back to: a built-in's shipped values, a custom density's built-in base.
    private var resetTarget: DensityTokens? {
        if let preset = DensityPreset(rawValue: selectedID) { return preset.tokens }
        guard let base = selected.basedOn.flatMap(DensityPreset.init(rawValue:)) else { return nil }
        var tokens = base.tokens
        tokens.id = selected.id
        tokens.name = selected.name
        tokens.basedOn = base.rawValue
        return tokens
    }

    /// Whether the selected density differs from what Reset goes back to.
    var selectedIsEdited: Bool { resetTarget.map { $0 != selected } ?? false }

    /// The built-ins the lab changed, for the Save line.
    var editedBuiltInCount: Int { zip(builtIns, DensityPreset.allCases).count { $0 != $1.tokens } }

    // MARK: Opening

    /// Reads the app's state again (the palette, the CLI or a cmux.json reload may have changed it) and the saved
    /// built-ins off the main actor; the first open also captures every density.
    func refresh(captureIfEmpty: Bool) {
        customs = design.customDensities
        if all.contains(where: { $0.id == design.densityTokens.id }) { selectedID = design.densityTokens.id }
        let url = fileURL
        Task { [weak self] in
            let saved = await Self.read(url)
            guard let self else { return }
            if !saved.isEmpty {
                builtIns = DensityPreset.allCases.map { preset in saved.first { $0.id == preset.rawValue } ?? preset.tokens }
                if selectedIsBuiltIn { design.densityTokens = selected }
            }
            if captureIfEmpty, captures.isEmpty { await captureAll() }
        }
    }

    // MARK: Editing

    /// Draws the app in `id`.
    func select(_ id: String) {
        guard all.contains(where: { $0.id == id }) else { return }
        selectedID = id
        design.densityTokens = selected
        if !selectedIsBuiltIn { hooks.saveCustom(customs, id) }
        scheduleRecapture()
    }

    /// Sets `control` on the selected density (nil: automatic) and draws the app in it at once.
    func set(_ control: DensityLabControl, _ value: Double?) {
        replaceSelected(control.applying(value.map { ($0 / control.step).rounded() * control.step }, to: selected))
    }

    /// A slider was let go, or a field committed: a custom density is saved and the selected density captured again.
    func editingEnded() {
        if !selectedIsBuiltIn { hooks.saveCustom(customs, selectedID) }
        scheduleRecapture()
    }

    /// Clears the card and tab radii, so they are concentric with the macOS window corner again.
    func matchWindowCorners() {
        var density = selected
        density.tokens[ChromeLabToken.cardRadius.rawValue] = nil
        density.tokens[ChromeLabToken.tabRadius.rawValue] = nil
        replaceSelected(density)
        editingEnded()
        status = "Corners are concentric with the \(Int(Metrics.standardWindowCornerRadius)) pt macOS window corner."
    }

    /// Puts the selected density back to its shipped values (a custom density: its base's).
    func resetSelected() {
        guard let target = resetTarget else { return }
        replaceSelected(target)
        editingEnded()
    }

    /// Makes a custom density from the selected one, saves it and draws the app in it.
    func newCustom(name: String = "My density") {
        let made = CustomDensitiesSetting.duplicate(selected, name: name, existing: customs)
        customs.append(made)
        selectedID = made.id
        design.densityTokens = made
        hooks.saveCustom(customs, made.id)
        status = "Made “\(made.name)”. Edits to it save to cmux.json."
        scheduleRecapture()
    }

    /// Renames the selected custom density.
    func rename(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedIsBuiltIn, !trimmed.isEmpty, let index = customs.firstIndex(where: { $0.id == selectedID }) else { return }
        customs[index].name = String(trimmed.prefix(64))
        design.densityTokens = customs[index]
        hooks.saveCustom(customs, selectedID)
    }

    /// Deletes the selected custom density and draws the app in its base.
    func deleteSelected() {
        guard !selectedIsBuiltIn, let index = customs.firstIndex(where: { $0.id == selectedID }) else { return }
        let gone = customs.remove(at: index)
        captures[gone.id] = nil
        let next = gone.basedOn.flatMap { id in builtIns.first { $0.id == id } } ?? builtIns[2]
        selectedID = next.id
        design.densityTokens = next
        hooks.saveCustom(customs, next.id)
        status = "Deleted “\(gone.name)”."
    }

    private func replaceSelected(_ density: DensityTokens) {
        if let index = builtIns.firstIndex(where: { $0.id == density.id }) {
            builtIns[index] = density
        } else if let index = customs.firstIndex(where: { $0.id == density.id }) {
            customs[index] = density
        } else {
            return
        }
        design.densityTokens = density
    }

    // MARK: Save and export

    /// Writes every built-in as the lab has it to ``fileURL``, off the main actor.
    func saveBuiltIns() {
        let url = fileURL, file = DensityLabFile(densities: builtIns)
        Task { [weak self] in
            let error = await Self.write(file, to: url)
            self?.status = error.map { "Save failed: \($0)" } ?? "Saved the built-ins to \(url.path)"
        }
    }

    /// Copies the `DensityPreset.tokens` switch with the lab's built-ins.
    func copyPresetCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(DensityLabExport.swift(builtIns), forType: .string)
        status = "Copied the DensityPreset.tokens code for the built-ins."
    }

    @concurrent private static func read(_ url: URL) async -> [DensityTokens] {
        guard let data = try? Data(blockingContentsOf: url), let file = try? JSONDecoder().decode(DensityLabFile.self, from: data) else { return [] }
        return file.densities.map {
            DensityTokens(id: $0.id, name: $0.name, basedOn: $0.basedOn, level: $0.level, spacing: $0.spacing,
                          fontSize: $0.fontSize, tokens: $0.tokens)
        }
    }

    @concurrent private static func write(_ file: DensityLabFile, to url: URL) async -> String? {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try FileManager.checked.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(file).blockingWrite(to: url, options: .atomic)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Loads an image to match, off the main actor.
    func loadReference(_ url: URL) {
        Task { [weak self] in
            guard let loaded = await Self.image(at: url) else { self?.status = "Could not read \(url.lastPathComponent)"; return }
            self?.reference = loaded.image
            self?.referenceScale = loaded.scale
        }
    }

    @concurrent private static func image(at url: URL) async -> (image: CGImage, scale: CGFloat)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = properties?[kCGImagePropertyDPIWidth] as? Double ?? 144
        return (image, max(1, (dpi / 72).rounded()))
    }

    // MARK: Captures

    /// Draws the main window at every density in turn, keeps a capture of each, then goes back to the selected one.
    func captureAll() async {
        guard !isCapturing else { return }
        guard let window = hooks.targetWindow() else { status = "Open a main window to see captures."; return }
        recapture?.cancel()
        isCapturing = true
        let keep = selected
        for density in all {
            design.densityTokens = density
            if let image = await capture(window) { captures[density.id] = image }
        }
        design.densityTokens = keep
        captureScale = window.backingScaleFactor
        isCapturing = false
        status = "Captured \(captures.count) densities."
    }

    /// Captures the selected density again; a newer request cancels an older one.
    private func scheduleRecapture() {
        guard !isCapturing, let window = hooks.targetWindow() else { return }
        recapture?.cancel()
        let id = selectedID
        recapture = Task { [weak self] in
            guard let self, let image = await capture(window), !Task.isCancelled else { return }
            captures[id] = image
            captureScale = window.backingScaleFactor
        }
    }

    /// The main window and its child windows (not the lab panel over it) once the density change has drawn: two
    /// frame commits, the first for the change's layout, the second for what that layout scheduled.
    private func capture(_ window: NSWindow) async -> CGImage? {
        for _ in 0..<2 { await withCheckedContinuation { done in AfterFrameCommit().run { done.resume() } } }
        guard let plan = window.compositedCapturePlan() else { return nil }
        return await Self.captured(plan)
    }

    @concurrent private static func captured(_ plan: WindowCapturePlan) async -> CGImage? { NSWindow.capture(plan) }
}

/// What Save writes.
nonisolated struct DensityLabFile: Codable, Sendable {
    var densities: [DensityTokens]
}
