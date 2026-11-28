"""Code generation for the cmux pane protocol IR (cmux-tui/spec/pane-protocol.json).

This lives in a subpackage, not as ``codegen/emit_go_pane.py``, because
``codegen/generate.py`` registers every ``emit_*.py`` beside it as an SDK
language and feeds it the mux SDK IR. The pane-protocol IR is a different
document with its own loader.
"""
