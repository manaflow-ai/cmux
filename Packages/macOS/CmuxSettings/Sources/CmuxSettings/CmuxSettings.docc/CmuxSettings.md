# ``CmuxSettings``

Strongly-typed, migratable settings storage for cmux. Foundation-only.

## Overview

`CmuxSettings` is the settings layer of cmux. It is built on three
principles:

- **Typed at compile time.** Each setting is a value-typed
  ``DefaultsKey`` or ``JSONKey`` declared once on a
  ``SettingCatalog``. Stores accept only their flavor; passing a
  ``JSONKey`` to ``UserDefaultsSettingsStore`` does not compile.
- **Modern Swift 6 concurrency.** Both stores are `actor`s.
  Observation is exposed as `AsyncStream<Value>`. There are no
  locks, no KVO, no `@Published`/`ObservableObject`, no
  completion-handler APIs.
- **Dependency-injected.** No shared singletons. The app constructs
  the catalog and the stores at startup and passes them to consumers.

## Topics

### Getting started

- ``SettingCatalog``
- ``UserDefaultsSettingsStore``
- ``JSONConfigStore``

### Declaring settings

- ``DefaultsKey``
- ``JSONKey``
- ``SettingCatalogSection``
- ``AppCatalogSection``
- ``AutomationCatalogSection``

### Value types

- ``SettingCodable``
- ``AppearanceMode``
- ``SocketControlMode``

### Type erasure and migration

- ``AnySettingKey``

### JSON config internals

- ``JSONCSanitizer``
- ``JSONPath``
- ``CmuxConfigLocation``
