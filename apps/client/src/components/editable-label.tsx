import { cn } from "@/lib/utils";
import { Check, Loader2, Pencil, X } from "lucide-react";
import {
  type FocusEvent,
  type KeyboardEvent,
  useLayoutEffect,
  useRef,
  useState,
} from "react";

type EditableLabelProps = {
  value: string;
  onSubmit: (nextValue: string) => Promise<boolean> | boolean;
  onEditStart?: () => void;
  onCancel?: () => void;
  isSaving?: boolean;
  error?: string | null;
  className?: string;
  labelClassName?: string;
  buttonLabel?: string;
  placeholder?: string;
  disabled?: boolean;
  ariaLabel?: string;
};

export function EditableLabel({
  value,
  onSubmit,
  onEditStart,
  onCancel,
  isSaving = false,
  error,
  className,
  labelClassName,
  buttonLabel = "Edit label",
  placeholder,
  disabled = false,
  ariaLabel,
}: EditableLabelProps) {
  const [isEditing, setIsEditing] = useState(false);
  const [isSubmitting, setIsSubmitting] = useState(false);
  const editableRef = useRef<HTMLDivElement | null>(null);
  const editButtonRef = useRef<HTMLButtonElement | null>(null);
  const draftRef = useRef(value);

  useLayoutEffect(() => {
    draftRef.current = value;
    if (isEditing) {
      return;
    }
    if (editableRef.current) {
      editableRef.current.textContent = value;
    }
  }, [value, isEditing]);

  useLayoutEffect(() => {
    if (!isEditing || !editableRef.current) {
      return;
    }
    const element = editableRef.current;
    element.focus();
    if (typeof window === "undefined") {
      return;
    }
    const selection = window.getSelection();
    const range = document.createRange();
    range.selectNodeContents(element);
    range.collapse(false);
    selection?.removeAllRanges();
    selection?.addRange(range);
  }, [isEditing]);

  const isBusy = isSaving || isSubmitting;

  const handleEditClick = () => {
    if (disabled) {
      return;
    }
    if (isEditing) {
      void handleSubmit();
      return;
    }
    onEditStart?.();
    draftRef.current = value;
    if (editableRef.current) {
      editableRef.current.textContent = value;
    }
    setIsEditing(true);
  };

  const handleCancel = () => {
    draftRef.current = value;
    setIsEditing(false);
    onCancel?.();
  };

  const handleSubmit = async () => {
    if (isBusy) {
      return;
    }
    const trimmed = draftRef.current.trim();
    if (trimmed === value.trim()) {
      handleCancel();
      return;
    }
    setIsSubmitting(true);
    try {
      const result = await onSubmit(trimmed);
      if (result) {
        draftRef.current = trimmed;
        setIsEditing(false);
      } else {
        editableRef.current?.focus();
      }
    } catch (error_) {
      console.error(error_);
      editableRef.current?.focus();
    } finally {
      setIsSubmitting(false);
    }
  };

  const handleInput = () => {
    draftRef.current = editableRef.current?.textContent ?? "";
  };

  const handleKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      void handleSubmit();
    }
    if (event.key === "Escape") {
      event.preventDefault();
      handleCancel();
    }
  };

  const handleBlur = (event: FocusEvent<HTMLDivElement>) => {
    if (!isEditing || isBusy) {
      return;
    }
    if (event.relatedTarget === editButtonRef.current) {
      return;
    }
    void handleSubmit();
  };

  return (
    <div className={cn("flex flex-col", className)}>
      <div className="inline-flex items-center">
        <div
          ref={editableRef}
          className={cn(
            "pl-1 text-xl font-semibold text-neutral-900 outline-none focus-visible:ring-2 focus-visible:ring-neutral-200 dark:text-neutral-100 dark:focus-visible:ring-neutral-800 pr-3",
            isEditing
              ? "rounded-md bg-neutral-100 dark:bg-neutral-900"
              : "bg-transparent",
            labelClassName,
          )}
          role="textbox"
          aria-label={ariaLabel ?? buttonLabel}
          aria-disabled={disabled || isBusy}
          aria-multiline="false"
          contentEditable={isEditing && !disabled}
          suppressContentEditableWarning
          spellCheck={false}
          data-placeholder={placeholder}
          data-cmux-inline-editing={isEditing ? "true" : undefined}
          onInput={handleInput}
          onKeyDown={handleKeyDown}
          onBlur={handleBlur}
        />
        <button
          ref={editButtonRef}
          type="button"
          onMouseDown={(event) => {
            // Prevent losing focus before click handler runs.
            event.preventDefault();
          }}
          onClick={handleEditClick}
          disabled={disabled || (isBusy && !isEditing)}
          className="inline-flex h-8 w-8 items-center justify-center rounded-md border border-transparent text-neutral-500 transition-colors hover:text-neutral-900 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-neutral-200 disabled:cursor-not-allowed disabled:opacity-60 dark:text-neutral-400 dark:hover:text-neutral-100 dark:focus-visible:ring-neutral-800"
        >
          {isEditing ? (
            isBusy ? (
              <Loader2 className="h-4 w-4 animate-spin" />
            ) : (
              <Check className="h-4 w-4" />
            )
          ) : (
            <Pencil className="h-4 w-4" />
          )}
          <span className="sr-only">{isEditing ? "Save" : buttonLabel}</span>
        </button>
        {isEditing ? (
          <button
            type="button"
            onMouseDown={(event) => {
              event.preventDefault();
            }}
            onClick={handleCancel}
            disabled={isBusy}
            className="inline-flex h-8 w-8 items-center justify-center rounded-md border border-transparent text-neutral-500 transition-colors hover:text-neutral-900 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-neutral-200 disabled:cursor-not-allowed disabled:opacity-60 dark:text-neutral-400 dark:hover:text-neutral-100 dark:focus-visible:ring-neutral-800"
          >
            <X className="h-4 w-4" aria-hidden="true" />
            <span className="sr-only">Cancel</span>
          </button>
        ) : null}
      </div>
      {error ? <p className="mt-1 text-xs text-red-500">{error}</p> : null}
    </div>
  );
}
