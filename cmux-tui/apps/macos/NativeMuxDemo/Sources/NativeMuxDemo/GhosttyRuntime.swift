import AppKit
import Foundation
import GhosttyKit

private let nativeGhosttyReadClipboardCallback:
  @convention(c) (
    UnsafeMutableRawPointer?,
    ghostty_clipboard_e,
    UnsafeMutableRawPointer?
  ) -> Bool = { _, _, _ in false }

/// One process-wide embedded libghostty runtime shared by every remote PTY
/// surface in the demo. GhosttyKit is a C ABI module imported directly by
/// Swift; AppKit remains the owner of windows, views, focus, and lifecycle.
@MainActor
final class NativeGhosttyRuntime: @unchecked Sendable {
  static let shared: NativeGhosttyRuntime? = NativeGhosttyRuntime()

  var app: ghostty_app_t { lifetime.app }
  private let lifetime: NativeGhosttyRuntimeLifetime
  private let ticker: NativeGhosttyTicker

  private init?() {
    if getenv("NO_COLOR") != nil {
      unsetenv("NO_COLOR")
    }
    guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
      return nil
    }
    guard let primaryConfig = Self.loadConfiguration() else { return nil }
    let ticker = NativeGhosttyTicker()

    var runtimeConfig = ghostty_runtime_config_s()
    runtimeConfig.userdata = Unmanaged.passUnretained(ticker).toOpaque()
    runtimeConfig.supports_selection_clipboard = false
    runtimeConfig.wakeup_cb = { userdata in
      guard let userdata else { return }
      Unmanaged<NativeGhosttyTicker>
        .fromOpaque(userdata)
        .takeUnretainedValue()
        .scheduleTick()
    }
    runtimeConfig.action_cb = { _, _, _ in false }
    runtimeConfig.read_clipboard_cb = nativeGhosttyReadClipboardCallback
    runtimeConfig.confirm_read_clipboard_cb = { _, _, _, _ in }
    runtimeConfig.write_clipboard_cb = { _, _, _, _, _ in }
    runtimeConfig.close_surface_cb = { _, _ in }

    guard let app = ghostty_app_new(&runtimeConfig, primaryConfig) else {
      ghostty_config_free(primaryConfig)
      guard let fallbackConfig = Self.loadFallbackConfiguration() else { return nil }
      guard let fallbackApp = ghostty_app_new(&runtimeConfig, fallbackConfig) else {
        ghostty_config_free(fallbackConfig)
        return nil
      }
      self.lifetime = NativeGhosttyRuntimeLifetime(app: fallbackApp, config: fallbackConfig)
      self.ticker = ticker
      ticker.app = fallbackApp
      ghostty_app_set_focus(fallbackApp, NSApp.isActive)
      return
    }
    lifetime = NativeGhosttyRuntimeLifetime(app: app, config: primaryConfig)
    self.ticker = ticker
    ticker.app = app
    ghostty_app_set_focus(app, NSApp.isActive)
  }

  private static func loadConfiguration() -> ghostty_config_t? {
    guard let config = ghostty_config_new() else { return nil }
    ghostty_config_load_default_files(config)
    ghostty_config_load_recursive_files(config)
    ghostty_config_finalize(config)
    return config
  }

  private static func loadFallbackConfiguration() -> ghostty_config_t? {
    guard let config = ghostty_config_new() else { return nil }
    let source = "NativeMuxDemo"
    let settings = "shell-integration = none\nmacos-background-from-layer = false"
    source.withCString { sourcePointer in
      settings.withCString { settingsPointer in
        ghostty_config_load_string(
          config,
          settingsPointer,
          UInt(settings.utf8.count),
          sourcePointer
        )
      }
    }
    ghostty_config_finalize(config)
    return config
  }

}

private final class NativeGhosttyRuntimeLifetime: @unchecked Sendable {
  let app: ghostty_app_t
  private let config: ghostty_config_t

  init(app: ghostty_app_t, config: ghostty_config_t) {
    self.app = app
    self.config = config
  }

  deinit {
    ghostty_app_free(app)
    ghostty_config_free(config)
  }
}

private final class NativeGhosttyTicker: @unchecked Sendable {
  var app: ghostty_app_t?
  private let tickLock = NSLock()
  private var tickScheduled = false

  func scheduleTick() {
    tickLock.lock()
    guard !tickScheduled else {
      tickLock.unlock()
      return
    }
    tickScheduled = true
    tickLock.unlock()
    DispatchQueue.main.async { [self] in
      tickLock.lock()
      tickScheduled = false
      tickLock.unlock()
      if let app {
        ghostty_app_tick(app)
      }
    }
  }
}
