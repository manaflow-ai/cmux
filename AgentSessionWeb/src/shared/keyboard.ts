export type ComposingEnterEvent = {
  key: string;
  isComposing?: boolean;
  keyCode?: number;
};

export function isComposingEnter(event: ComposingEnterEvent, editorIsComposing = false): boolean {
  return event.key === "Enter" && (event.isComposing === true || editorIsComposing || event.keyCode === 229);
}
