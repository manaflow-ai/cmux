"""The Swift app's daemon request types, generated from the SDK schema (cmux-tui/spec/sdk-schema.json).

This lives in a subpackage, not as ``codegen/emit_swift.py``, because ``codegen/generate.py`` registers
every ``emit_*.py`` beside it as an SDK language whose output stays under ``cmux-tui/bindings``. These
files go into the app's CmuxNextDaemon target instead, one file per request type, and only for the
commands that ``bindings.json`` lists: the app's hand-written request types move to generated ones one
family at a time. They are not in git: CmuxNextDaemon's DaemonRequestsPlugin writes them into its build
work directory (``generate.py --out``). ``codegen/generate.py`` runs ``generate.py --check`` after the SDKs,
so a schema change that breaks a binding fails there too.
"""
