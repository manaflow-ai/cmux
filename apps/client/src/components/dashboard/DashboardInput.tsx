import LexicalEditor from "@/components/lexical/LexicalEditor";
import clsx from "clsx";
import { forwardRef, memo, useImperativeHandle, useRef, useMemo } from "react";

export interface EditorApi {
  getContent: () => {
    text: string;
    images: Array<{
      src: string;
      fileName?: string;
      altText: string;
    }>;
  };
  clear: () => void;
  focus?: () => void;
  insertText?: (text: string) => void;
}

interface DashboardInputProps {
  onTaskDescriptionChange: (value: string) => void;
  onSubmit: () => void;
  repoUrl?: string;
  branch?: string;
  persistenceKey?: string;
  maxHeight?: string;
}

export const DashboardInput = memo(
  forwardRef<EditorApi, DashboardInputProps>(function DashboardInput(
    {
      onTaskDescriptionChange,
      onSubmit,
      repoUrl,
      branch,
      persistenceKey,
      maxHeight = "600px",
    },
    ref
  ) {
    const internalApiRef = useRef<EditorApi | null>(null);
    const hasFocusedRef = useRef(false);

    useImperativeHandle(ref, () => ({
      getContent: () => internalApiRef.current?.getContent() || { text: "", images: [] },
      clear: () => internalApiRef.current?.clear(),
      focus: () => internalApiRef.current?.focus?.(),
      insertText: (text: string) => internalApiRef.current?.insertText?.(text),
    }));

    const lexicalPlaceholder = useMemo(() => "Describe a task", []);

    const lexicalPadding = useMemo(
      () => ({
        paddingLeft: "14px",
        paddingRight: "16px",
        paddingTop: "14px",
      }),
      []
    );

    const lexicalClassName = useMemo(
      () =>
        clsx(
          "text-[15px] text-neutral-900 dark:text-neutral-100 min-h-[60px]!",
          "focus:outline-none"
        ),
      []
    );

    const handleEditorReady = (api: EditorApi) => {
      internalApiRef.current = api;
      
      // Autofocus the editor when it's ready (only once)
      if (!hasFocusedRef.current) {
        // Small delay to ensure the editor is fully rendered
        setTimeout(() => {
          api.focus?.();
          hasFocusedRef.current = true;
        }, 100);
      }
    };

    return (
      <LexicalEditor
        placeholder={lexicalPlaceholder}
        onChange={onTaskDescriptionChange}
        onSubmit={onSubmit}
        repoUrl={repoUrl}
        branch={branch}
        persistenceKey={persistenceKey}
        padding={lexicalPadding}
        contentEditableClassName={lexicalClassName}
        maxHeight={maxHeight}
        onEditorReady={handleEditorReady}
      />
    );
  })
);