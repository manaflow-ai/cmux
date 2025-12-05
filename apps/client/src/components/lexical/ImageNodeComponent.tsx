import { $getNodeByKey, type LexicalEditor } from "lexical";
import { useCallback } from "react";
import ImageComponent from "./ImageComponent";

interface ImageNodeComponentProps {
  src: string;
  altText: string;
  fileName?: string;
  nodeKey: string;
  editor: LexicalEditor;
}

export function ImageNodeComponent({
  src,
  altText,
  fileName,
  nodeKey,
  editor,
}: ImageNodeComponentProps) {
  const handleRemove = useCallback(() => {
    editor.update(() => {
      const node = $getNodeByKey(nodeKey);
      if (node) {
        node.remove();
      }
    });
  }, [editor, nodeKey]);

  return (
    <ImageComponent
      src={src}
      altText={altText}
      fileName={fileName}
      nodeKey={nodeKey}
      onRemove={handleRemove}
    />
  );
}
