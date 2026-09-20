# CmuxComputerUseCore

This package owns the pure Computer Use onboarding state, helper signing
identity, and versioned completion record. The app target supplies daemon,
capture, and UI adapters through injected operations; the package never
launches a helper or reads live user state beyond the `UserDefaults` instance
provided to its store.
