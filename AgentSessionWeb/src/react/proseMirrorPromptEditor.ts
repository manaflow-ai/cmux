import React, { useImperativeHandle, useLayoutEffect, useRef } from "react";
import { Schema } from "prosemirror-model";
import { splitBlock } from "prosemirror-commands";
import { EditorState, Plugin, PluginKey, TextSelection } from "prosemirror-state";
import { Decoration, DecorationSet, EditorView } from "prosemirror-view";
import { isComposingEnter } from "../shared/keyboard";

const promptSchema = new Schema({
  nodes: {
    doc: { content: "paragraph+" },
    paragraph: {
      content: "inline*",
      group: "block",
      parseDOM: [{ tag: "p" }],
      toDOM: () => ["p", 0],
    },
    text: { group: "inline" },
  },
  marks: {},
});

const placeholderKey = new PluginKey<string>("agentPromptPlaceholder");

export type PromptEditorHandle = {
  focus: () => void;
  insertText: (text: string) => void;
};

type PromptEditorProps = {
  ariaLabel?: string;
  className?: string;
  minHeight?: string;
  onSubmit: () => void;
  onTextChange: (text: string) => void;
  onTriggerToken?: (token: "@" | "$") => void;
  placeholder: string;
  value: string;
};

export const PromptEditor = React.forwardRef<PromptEditorHandle, PromptEditorProps>(
  function PromptEditor(
    { ariaLabel, className, minHeight = "2.75rem", onSubmit, onTextChange, onTriggerToken, placeholder, value },
    ref,
  ) {
    const hostRef = useRef<HTMLDivElement | null>(null);
    const viewRef = useRef<EditorView | null>(null);
    const latestSubmitRef = useRef(onSubmit);
    const latestTextChangeRef = useRef(onTextChange);
    const latestTriggerTokenRef = useRef(onTriggerToken);
    const latestTextRef = useRef(value);
    latestSubmitRef.current = onSubmit;
    latestTextChangeRef.current = onTextChange;
    latestTriggerTokenRef.current = onTriggerToken;

    useImperativeHandle(ref, () => ({
      focus() {
        viewRef.current?.focus();
      },
      insertText(text) {
        const view = viewRef.current;
        if (!view) {
          return;
        }
        insertPromptTextAtSelection(view, text);
      },
    }), []);

    useLayoutEffect(() => {
      const host = hostRef.current;
      if (!host) {
        return;
      }
      const view = new EditorView(host, {
        state: EditorState.create({
          doc: docFromText(value),
          plugins: [placeholderPlugin(placeholder)],
        }),
        attributes: {
          "aria-label": ariaLabel ?? placeholder,
          "data-codex-composer": "true",
          role: "textbox",
          class: "ProseMirror prompt-editor-view",
          style: `min-height: ${minHeight};`,
        },
        dispatchTransaction(transaction) {
          const nextState = view.state.apply(transaction);
          view.updateState(nextState);
          const nextText = textFromDoc(nextState.doc);
          const previousText = latestTextRef.current;
          if (nextText !== previousText) {
            latestTextRef.current = nextText;
            const insertedTrigger = singleInsertedTrigger(previousText, nextText);
            if (insertedTrigger) {
              latestTriggerTokenRef.current?.(insertedTrigger);
            }
            latestTextChangeRef.current(nextText);
          }
        },
        handleKeyDown(_view, event) {
          if (isComposingEnter(event, _view.composing)) {
            return false;
          }
          if ((event.metaKey || event.ctrlKey) && event.key === "Enter") {
            event.preventDefault();
            latestSubmitRef.current();
            return true;
          }
          if (event.key !== "Enter") {
            return false;
          }
          if (event.shiftKey || event.altKey) {
            event.preventDefault();
            return splitBlock(_view.state, _view.dispatch, _view);
          }
          event.preventDefault();
          latestSubmitRef.current();
          return true;
        },
        handleTextInput(_view, _from, _to, text) {
          if (text === "@" || text === "$") {
            latestTriggerTokenRef.current?.(text);
          }
          return false;
        },
      });
      viewRef.current = view;
      return () => {
        view.destroy();
        viewRef.current = null;
      };
    }, []);

    useLayoutEffect(() => {
      const view = viewRef.current;
      if (!view) {
        return;
      }
      view.dispatch(view.state.tr.setMeta(placeholderKey, placeholder));
    }, [placeholder]);

    useLayoutEffect(() => {
      const view = viewRef.current;
      if (!view) {
        return;
      }
      const nextLabel = ariaLabel ?? placeholder;
      if (nextLabel) {
        view.dom.setAttribute("aria-label", nextLabel);
      } else {
        view.dom.removeAttribute("aria-label");
      }
    }, [ariaLabel, placeholder]);

    useLayoutEffect(() => {
      const view = viewRef.current;
      if (!view) {
        return;
      }
      view.dom.style.minHeight = minHeight;
    }, [minHeight]);

    useLayoutEffect(() => {
      const view = viewRef.current;
      if (!view || value === latestTextRef.current) {
        return;
      }
      latestTextRef.current = value;
      replaceEditorText(view, value);
    }, [value]);

    return React.createElement("div", { className, ref: hostRef });
  },
);

function singleInsertedTrigger(previous: string, next: string): "@" | "$" | null {
  if (next.length !== previous.length + 1) {
    return null;
  }
  let prefixLength = 0;
  while (
    prefixLength < previous.length &&
    previous.charCodeAt(prefixLength) === next.charCodeAt(prefixLength)
  ) {
    prefixLength += 1;
  }
  let suffixLength = 0;
  while (
    suffixLength < previous.length - prefixLength &&
    previous.charCodeAt(previous.length - 1 - suffixLength) ===
      next.charCodeAt(next.length - 1 - suffixLength)
  ) {
    suffixLength += 1;
  }
  const inserted = next.slice(prefixLength, next.length - suffixLength);
  return inserted === "@" || inserted === "$" ? inserted : null;
}

function placeholderPlugin(initialPlaceholder: string): Plugin {
  return new Plugin<string>({
    key: placeholderKey,
    state: {
      init: () => initialPlaceholder,
      apply(transaction, previous) {
        return transaction.getMeta(placeholderKey) ?? previous;
      },
    },
    props: {
      decorations(state) {
        const placeholder = placeholderKey.getState(state) ?? "";
        if (!placeholder || state.doc.childCount !== 1) {
          return null;
        }
        const firstChild = state.doc.firstChild;
        if (!firstChild?.isTextblock || firstChild.content.size !== 0) {
          return null;
        }
        return DecorationSet.create(state.doc, [
          Decoration.node(0, firstChild.nodeSize, {
            class: "placeholder",
            "data-placeholder": placeholder,
          }),
        ]);
      },
    },
  });
}

function docFromText(text: string) {
  const paragraphs = text.split("\n");
  return promptSchema.nodes.doc.create(null, paragraphs.map((paragraph) => {
    return promptSchema.nodes.paragraph.create(
      null,
      paragraph.length > 0 ? promptSchema.text(paragraph) : null,
    );
  }));
}

function textFromDoc(doc: ReturnType<typeof docFromText>): string {
  const paragraphs: string[] = [];
  doc.forEach((node) => {
    paragraphs.push(node.textContent);
  });
  return paragraphs.join("\n");
}

function replaceEditorText(view: EditorView, text: string): void {
  const doc = docFromText(text);
  const transaction = view.state.tr.replaceWith(0, view.state.doc.content.size, doc.content);
  transaction.setSelection(TextSelection.atEnd(transaction.doc));
  view.dispatch(transaction);
}

function insertPromptTextAtSelection(view: EditorView, text: string): void {
  const { state } = view;
  const { from, to } = state.selection;
  const trigger = text.startsWith("@") ? "@" : text.startsWith("$") ? "$" : null;
  const previousCharacter = state.doc.textBetween(Math.max(0, from - 1), from, "\n", "\n");
  const insertFrom = trigger && previousCharacter === trigger ? from - 1 : from;
  const before = state.doc.textBetween(Math.max(0, insertFrom - 2), insertFrom, "\n", "\n");
  const after = state.doc.textBetween(to, Math.min(state.doc.content.size, to + 2), "\n", "\n");
  const prefix = before.length > 0 && !/\s$/.test(before) ? " " : "";
  const suffix = after.length > 0 && !/^\s/.test(after) ? " " : "";
  const inserted = `${prefix}${text}${suffix}`;
  const transaction = state.tr.insertText(inserted, insertFrom, to);
  const cursor = insertFrom + inserted.length;
  transaction.setSelection(TextSelection.create(transaction.doc, cursor));
  view.dispatch(transaction);
  view.focus();
}
