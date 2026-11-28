"""The Swift app's daemon request types, generated from the SDK schema (cmux-tui/spec/sdk-schema.json).

This lives in a subpackage, not as ``codegen/emit_swift.py``, because ``codegen/generate.py`` registers
every ``emit_*.py`` beside it as an SDK language whose output is committed under ``cmux-tui/bindings``.
These files are build output instead: the SwiftPM build tool plugin
Packages/macOS/CmuxNext/Plugins/DaemonWireTypes runs ``generate.py --out`` before every build of the
CmuxNextDaemon target, for the families ``bindings.json`` lists. ``codegen/generate.py`` runs
``generate.py --check`` after the SDKs.
"""
