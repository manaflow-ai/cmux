import AppKit
public import CmuxNextCompat

// What the terminal key path needs from the system's input sources, read when they change and not once
// per key: the input-source switch keys (`InputSourceSwitchKeys`), the kind of the selected source and
// copy mode's ASCII map.

/// The terminal key path's view of the input sources, kept current by notifications so a key reads
/// Text Input Sources only when it may switch the source.
///
/// A key-down that may switch the source compares the source before and after `interpretKeyEvents` and
/// does not reach the terminal when it changed. That is a key with Control, Option, Command or Fn that is
/// a system switch key (``InputSourceSwitchKeys``), or any such key while an input method is selected
/// (its own mode keys, as Kotoeri's Ctrl-Shift-J, change the source too). Ctrl-C under a keyboard layout
/// reads nothing. Until ``start(runner:)`` has read the switch keys, every such key compares.
///
/// One per process, owned by `GhosttyRuntime` (`inputSources`), whose activation and keyboard-selection
/// observers call ``applicationDidBecomeActive()`` and ``selectedSourceChanged()``; the app starts it
/// with its runner.
public final class TerminalInputSources {
    private let reader: TerminalInputSourceReader
    private let readSwitchKeys: @Sendable () -> InputSourceSwitchKeys
    /// The system switch keys; nil until read.
    var switchKeys: InputSourceSwitchKeys?
    /// Whether the selected source is a keyboard layout; nil until read after a change.
    private var sourceIsLayout: Bool?
    private var asciiKeys: ASCIIKeyMap?
    private var runner: (any MayBlockRunner)?
    private var refresh: Task<Void, Never>?

    init(reader: TerminalInputSourceReader = .live,
         readSwitchKeys: @escaping @Sendable () -> InputSourceSwitchKeys = { InputSourceSwitchKeys.readSystem() }) {
        self.reader = reader
        self.readSwitchKeys = readSwitchKeys
    }

    /// Reads the switch keys on `runner` now and on each ``applicationDidBecomeActive()`` (the user changes
    /// them in System Settings). Once; later calls do nothing.
    public func start(runner: any MayBlockRunner) {
        guard self.runner == nil else { return }
        self.runner = runner
        selectedSourceChanged()
        refreshSwitchKeys()
    }

    /// Reads the switch keys on `runner` and keeps them, unless a newer read replaced this one.
    func loadSwitchKeys(on runner: any MayBlockRunner) async {
        guard let keys = try? await runner.runSystem(.bestEffort, readSwitchKeys), !Task.isCancelled else { return }
        switchKeys = keys
    }

    // MARK: Key path

    /// Whether a key-down of `keyCode` with `flags` may switch the input source, so the key path compares
    /// ``currentSourceID()`` before and ``sourceChanged(since:)`` after it. Reads Text Input Sources only
    /// for the first such key after a source change.
    func mayChangeSource(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        guard GhosttyInput.mayChangeInputSource(flags) else { return false }
        guard let switchKeys else { return true }
        return switchKeys.matches(keyCode: keyCode, flags: flags) || !currentSourceIsLayout()
    }

    /// The selected source's ID now (one Text Input Sources read).
    func currentSourceID() -> String? {
        reader.current()?.id
    }

    /// Whether the selected source is no longer `before` (one Text Input Sources read); a change also
    /// updates the cached kind and drops the ASCII map.
    func sourceChanged(since before: String?) -> Bool {
        let after = reader.current()
        guard after?.id != before else { return false }
        sourceIsLayout = after?.isKeyboardLayout
        asciiKeys = nil
        return true
    }

    /// Copy mode's ASCII characters for the selected layout, built on first use after a change.
    func asciiKeyMap() -> ASCIIKeyMap {
        if let asciiKeys { return asciiKeys }
        let built = reader.asciiKeyMap()
        asciiKeys = built
        return built
    }

    // MARK: Changes

    /// The selected source changed (or may have, while the app was inactive): reads its kind now, off the
    /// key path, and drops the ASCII map.
    func selectedSourceChanged() {
        asciiKeys = nil
        sourceIsLayout = reader.current()?.isKeyboardLayout
    }

    /// The app became active: the source or the switch keys may have changed meanwhile.
    func applicationDidBecomeActive() {
        selectedSourceChanged()
        refreshSwitchKeys()
    }

    private func refreshSwitchKeys() {
        guard let runner else { return }
        refresh?.cancel()
        refresh = Task { [weak self] in await self?.loadSwitchKeys(on: runner) }
    }

    private func currentSourceIsLayout() -> Bool {
        if let sourceIsLayout { return sourceIsLayout }
        guard let isLayout = reader.current()?.isKeyboardLayout else { return false }
        sourceIsLayout = isLayout
        return isLayout
    }
}
