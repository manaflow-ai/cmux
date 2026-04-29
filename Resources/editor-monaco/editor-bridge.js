// editor-bridge.js — cmux Editor ↔ Monaco bridge
// Exposes window.cmuxEditor for Swift to call, posts messages via
// window.webkit.messageHandlers.cmuxEditor for Monaco → Swift events.

(function () {
  "use strict";

  var editor = null;
  var diffEditor = null;
  var diffOriginalModel = null;
  var diffModifiedModel = null;
  var isDiffMode = false;
  var currentLanguage = "plaintext";
  var currentFilePath = "";
  var suppressContentChanged = false;

  // Post message to Swift.
  function postToNative(msg) {
    if (
      window.webkit &&
      window.webkit.messageHandlers &&
      window.webkit.messageHandlers.cmuxEditor
    ) {
      window.webkit.messageHandlers.cmuxEditor.postMessage(msg);
    }
  }

  // Detect dark mode from prefers-color-scheme or Swift override.
  function detectTheme() {
    return window.matchMedia &&
      window.matchMedia("(prefers-color-scheme: dark)").matches
      ? "vs-dark"
      : "vs";
  }

  function editorOptions(value, language) {
    return {
      value: value || "",
      language: language || "plaintext",
      theme: detectTheme(),
      readOnly: false,
      automaticLayout: true,
      minimap: { enabled: true },
      scrollBeyondLastLine: false,
      fontSize: 12,
      fontFamily: '"SF Mono", Menlo, Monaco, "Courier New", monospace',
      lineNumbers: "on",
      renderWhitespace: "none",
      wordWrap: "off",
      folding: true,
      glyphMargin: false,
      largeFileOptimizations: true,
      maxTokenizationLineLength: 20000,
      scrollbar: {
        verticalScrollbarSize: 10,
        horizontalScrollbarSize: 10,
      },
      overviewRulerLanes: 0,
      hideCursorInOverviewRuler: true,
      contextmenu: false,
      domReadOnly: false,
    };
  }

  function wireNormalEditor() {
    if (!editor) return;

    editor.onDidChangeCursorSelection(function () {
      var selection = editor.getSelection();
      var hasSelection = selection !== null && !selection.isEmpty();
      postToNative({ type: "selectionChanged", hasSelection: hasSelection });
    });

    editor.onDidChangeModelContent(function () {
      if (!suppressContentChanged && !isDiffMode) {
        postToNative({ type: "contentChanged" });
      }
    });

    editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS, function () {
      postToNative({ type: "saveRequested" });
    });
  }

  function replaceEditorContent(content, language) {
    if (!editor) return;
    var model = editor.getModel();
    if (!model) return;

    suppressContentChanged = true;
    try {
      model.setValue(content);
      monaco.editor.setModelLanguage(model, language || "plaintext");
    } finally {
      suppressContentChanged = false;
    }
  }

  function disposeDiffEditor() {
    if (diffEditor) {
      diffEditor.dispose();
      diffEditor = null;
    }
    if (diffOriginalModel) {
      diffOriginalModel.dispose();
      diffOriginalModel = null;
    }
    if (diffModifiedModel) {
      diffModifiedModel.dispose();
      diffModifiedModel = null;
    }
    isDiffMode = false;
  }

  function disposeNormalEditor() {
    if (!editor) return;
    var model = editor.getModel();
    editor.dispose();
    editor = null;
    if (model) {
      model.dispose();
    }
  }

  // Initialize Monaco.
  function initMonaco() {
    require.config({
      paths: { vs: "vs" },
    });

    require(["vs/editor/editor.main"], function () {
      var container = document.getElementById("editor-container");
      container.innerHTML = "";

      editor = monaco.editor.create(
        container,
        editorOptions("", "plaintext")
      );
      wireNormalEditor();

      // Listen for theme changes.
      if (window.matchMedia) {
        window
          .matchMedia("(prefers-color-scheme: dark)")
          .addEventListener("change", function (e) {
            var theme = e.matches ? "vs-dark" : "vs";
            monaco.editor.setTheme(theme);
          });
      }

      postToNative({ type: "ready" });
    });
  }

  // Public API callable from Swift via evaluateJavaScript.
  window.cmuxEditor = {
    // Set file content in the normal (non-diff) editor.
    setContent: function (content, language, filePath) {
      currentLanguage = language || "plaintext";
      currentFilePath = filePath || "";

      if (isDiffMode && diffEditor) {
        disposeDiffEditor();
        document.getElementById("editor-container").innerHTML = "";
        editor = monaco.editor.create(
          document.getElementById("editor-container"),
          editorOptions(content, currentLanguage)
        );
        wireNormalEditor();
      } else if (editor) {
        replaceEditorContent(content, currentLanguage);
      }
    },

    // Enter diff mode: show original (base) vs modified (current).
    setDiffContent: function (original, modified, language) {
      var lang = language || currentLanguage;
      disposeDiffEditor();

      disposeNormalEditor();

      var container = document.getElementById("editor-container");
      container.innerHTML = "";

      diffOriginalModel = monaco.editor.createModel(original, lang);
      diffModifiedModel = monaco.editor.createModel(modified, lang);

      diffEditor = monaco.editor.createDiffEditor(container, {
        theme: detectTheme(),
        readOnly: true,
        automaticLayout: true,
        renderSideBySide: true,
        fontSize: 12,
        fontFamily:
          '"SF Mono", Menlo, Monaco, "Courier New", monospace',
        minimap: { enabled: false },
        scrollBeyondLastLine: false,
        glyphMargin: false,
        contextmenu: false,
        domReadOnly: true,
      });

      diffEditor.setModel({
        original: diffOriginalModel,
        modified: diffModifiedModel,
      });
      isDiffMode = true;

      // Track selection on the modified side.
      var modifiedEditor = diffEditor.getModifiedEditor();
      modifiedEditor.onDidChangeCursorSelection(function () {
        var selection = modifiedEditor.getSelection();
        var hasSelection = selection !== null && !selection.isEmpty();
        postToNative({ type: "selectionChanged", hasSelection: hasSelection });
      });
    },

    // Get the currently selected text.
    getSelection: function () {
      var activeEditor = isDiffMode
        ? diffEditor
          ? diffEditor.getModifiedEditor()
          : null
        : editor;
      if (!activeEditor) return "";
      var selection = activeEditor.getSelection();
      if (!selection || selection.isEmpty()) return "";
      return activeEditor.getModel().getValueInRange(selection);
    },

    // Get all content.
    getContent: function () {
      var activeEditor = isDiffMode
        ? diffEditor
          ? diffEditor.getModifiedEditor()
          : null
        : editor;
      if (!activeEditor) return "";
      return activeEditor.getValue();
    },

    // Trigger send-selection flow: get selection and post to Swift.
    triggerSendSelection: function () {
      var text = window.cmuxEditor.getSelection();
      if (text) {
        postToNative({ type: "sendSelection", content: text });
      }
    },

    // Show Monaco's in-file find widget.
    triggerFind: function () {
      var activeEditor = isDiffMode
        ? diffEditor
          ? diffEditor.getModifiedEditor()
          : null
        : editor;
      if (!activeEditor) return;
      activeEditor.focus();
      var action = activeEditor.getAction("actions.find");
      if (action) action.run();
    },

    // Set theme explicitly from Swift.
    setTheme: function (isDark) {
      monaco.editor.setTheme(isDark ? "vs-dark" : "vs");
    },

    // Go to a specific line and column.
    goToLine: function (line, column) {
      var activeEditor = isDiffMode
        ? diffEditor
          ? diffEditor.getModifiedEditor()
          : null
        : editor;
      if (!activeEditor) return;
      var col = column || 1;
      activeEditor.revealLineInCenter(line);
      activeEditor.setPosition({ lineNumber: line, column: col });
      activeEditor.focus();
    },
  };

  // Boot.
  initMonaco();
})();
