import { useContext } from "react";
import { DiffCommentsContext } from "./diff-comments-context-value";

export function useDiffComments() {
  const context = useContext(DiffCommentsContext);
  if (!context) {
    throw new Error("useDiffComments must be used within a DiffCommentsProvider");
  }
  return context;
}

export function useDiffCommentsOptional() {
  return useContext(DiffCommentsContext);
}
