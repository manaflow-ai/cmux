import CmuxSimulator
import Foundation
import ObjectiveC.runtime

/// Owns SimulatorKit's process-global input capture inside the crash-isolated worker.
@MainActor
final class SimulatorHIDCaptureAdapter {
  private typealias SharedManagerFunction = @convention(c) (AnyClass, Selector) -> AnyObject?
  private typealias StartFunction =
    @convention(c) (
      AnyObject,
      Selector,
      AnyObject,
      UInt64,
      AutoreleasingUnsafeMutablePointer<NSError?>
    ) -> ObjCBool
  private typealias StopFunction = @convention(c) (AnyObject, Selector) -> Void
  private typealias CapturedTypesFunction = @convention(c) (AnyObject, Selector) -> UInt64

  private static let keyboardType: UInt64 = 1
  private static let pointerType: UInt64 = 2

  private var manager: AnyObject?
  private var observers: [NSObjectProtocol] = []
  var onModeChange: (@MainActor (SimulatorHIDCaptureMode) -> Void)?

  var isAvailable: Bool { resolveManager() != nil }

  deinit {
    MainActor.assumeIsolated {
      stop()
      for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
  }

  @discardableResult
  func setMode(_ mode: SimulatorHIDCaptureMode, device: NSObject?) -> Bool {
    guard mode != .none else {
      stop()
      return true
    }
    guard let device, let manager = resolveManager() else { return false }
    let selector = NSSelectorFromString("startCaptureSessionWithDevice:hidDeviceTypes:error:")
    guard let implementation = class_getMethodImplementation(type(of: manager), selector) else {
      return false
    }
    let types: UInt64 =
      switch mode {
      case .none: 0
      case .keyboard: Self.keyboardType
      case .pointerAndKeyboard: Self.keyboardType | Self.pointerType
      }
    var error: NSError?
    let succeeded = unsafeBitCast(implementation, to: StartFunction.self)(
      manager,
      selector,
      device,
      types,
      &error
    )
    if succeeded.boolValue { reportCurrentMode() }
    return succeeded.boolValue
  }

  func stop() {
    guard let manager = resolveManager() else { return }
    let selector = NSSelectorFromString("stopCaptureSession")
    guard let implementation = class_getMethodImplementation(type(of: manager), selector) else {
      return
    }
    unsafeBitCast(implementation, to: StopFunction.self)(manager, selector)
    onModeChange?(.none)
  }

  private func resolveManager() -> AnyObject? {
    if let manager { return manager }
    guard let managerClass = NSClassFromString("SimHIDCaptureManager"),
      let metaclass = object_getClass(managerClass)
    else { return nil }
    let selector = NSSelectorFromString("sharedManager")
    guard let implementation = class_getMethodImplementation(metaclass, selector),
      let manager = unsafeBitCast(implementation, to: SharedManagerFunction.self)(
        managerClass,
        selector
      )
    else { return nil }
    self.manager = manager
    installObservers()
    return manager
  }

  private func installObservers() {
    guard observers.isEmpty else { return }
    for name in [
      "SimHIDCaptureManagerCaptureStartedNotification",
      "SimHIDCaptureManagerCaptureStoppedNotification",
    ] {
      observers.append(
        NotificationCenter.default.addObserver(
          forName: Notification.Name(name),
          object: manager,
          queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated { self?.reportCurrentMode() }
        })
    }
  }

  private func reportCurrentMode() {
    guard let manager else {
      onModeChange?(.none)
      return
    }
    let selector = NSSelectorFromString("currentlyCapturedTypes")
    guard let implementation = class_getMethodImplementation(type(of: manager), selector) else {
      onModeChange?(.none)
      return
    }
    let types = unsafeBitCast(implementation, to: CapturedTypesFunction.self)(manager, selector)
    if types & Self.pointerType != 0 {
      onModeChange?(.pointerAndKeyboard)
    } else if types & Self.keyboardType != 0 {
      onModeChange?(.keyboard)
    } else {
      onModeChange?(.none)
    }
  }
}
