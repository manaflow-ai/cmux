public import CmuxSafeConcurrency

// CmuxSafeConcurrency's callback registry under the names cmux-next code uses, which imports this module and
// not the shared package (as with `Mutex`). A C callback's context is a `CallbackToken`, never an unretained
// object.

/// A lock-free table from C callback contexts to their Swift objects (CmuxSafeConcurrency.CallbackRegistry).
public typealias CallbackRegistry<Target: AnyObject & Sendable> = CmuxSafeConcurrency.CallbackRegistry<Target>

/// The context a C callback gets back for a ``CallbackRegistry`` entry (CmuxSafeConcurrency.CallbackToken).
public typealias CallbackToken = CmuxSafeConcurrency.CallbackToken

/// A full ``CallbackRegistry`` (CmuxSafeConcurrency.CallbackRegistryError).
public typealias CallbackRegistryError = CmuxSafeConcurrency.CallbackRegistryError
