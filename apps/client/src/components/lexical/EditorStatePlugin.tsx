import { useLexicalComposerContext } from "@lexical/react/LexicalComposerContext";
import {
  $getRoot,
  $createParagraphNode,
  $getSelection,
  $createTextNode,
  ParagraphNode,
  type LexicalNode,
  ElementNode,
  TextNode,
} from "lexical";
import { useEffect } from "react";
import { $isImageNode } from "./ImageNode";
import type { Id } from "@cmux/convex/dataModel";

interface ExtractedContent {
  text: string;
  images: Array<
    | {
        src: string;
        fileName?: string;
        altText: string;
      }
    | {
        storageId: Id<"_storage">;
        fileName?: string;
        altText: string;
      }
  >;
}

interface EditorApi {
  getContent: () => {
    text: string;
    images: ExtractedContent["images"];
  };
  clear: () => void;
  focus: () => void;
  insertText: (text: string) => void;
}

export function EditorStatePlugin({ onEditorReady }: { onEditorReady?: (api: EditorApi) => void }) {
  const [editor] = useLexicalComposerContext();

  useEffect(() => {
    if (onEditorReady) {
      const api = {
        getContent: (): ExtractedContent => {
          const content: ExtractedContent = {
            text: "",
            images: []
          };

          editor.getEditorState().read(() => {
            const root = $getRoot();
            const textParts: string[] = [];
            
            // Walk through all nodes to build text with image references
            const walkNode = (node: LexicalNode): void => {
              if ($isImageNode(node)) {
                const fileName = node.getFileName();
                const altText = node.getAltText();
                
                // Add image to images array
                content.images.push({
                  src: node.getSrc(),
                  fileName: fileName,
                  altText: altText
                });
                
                // Add image reference to text
                if (fileName) {
                  textParts.push(fileName);
                } else {
                  textParts.push(`[Image: ${altText}]`);
                }
              } else if (node instanceof TextNode) {
                textParts.push(node.getTextContent());
              } else if (node instanceof ElementNode) {
                const children = node.getChildren();
                children.forEach(walkNode);
                // Add newline after paragraphs
                if (node.getType() === 'paragraph' && textParts.length > 0) {
                  textParts.push('\n');
                }
              }
            };

            const children = root.getChildren();
            children.forEach(walkNode);

            // Build final text
            content.text = textParts.join('').trim();
          });

          return content;
        },
        clear: () => {
          editor.update(() => {
            const root = $getRoot();
            root.clear();
            const paragraph = $createParagraphNode();
            root.append(paragraph);
            paragraph.select();
          });
        },
        focus: () => {
          editor.focus();
        },
        insertText: (text: string) => {
          editor.update(() => {
            const selection = $getSelection();
            if (selection) {
              selection.insertText(text);
            } else {
              // If no selection, append to the last paragraph
              const root = $getRoot();
              const children = root.getChildren();
              let lastParagraph: ParagraphNode | null = null;
              
              // Find the last paragraph node
              for (let i = children.length - 1; i >= 0; i--) {
                if (children[i].getType() === 'paragraph') {
                  lastParagraph = children[i] as ParagraphNode;
                  break;
                }
              }
              
              // If no paragraph exists, create one
              if (!lastParagraph) {
                lastParagraph = $createParagraphNode();
                root.append(lastParagraph);
              }
              
              // Append the text node to the paragraph
              const textNode = $createTextNode(text);
              lastParagraph.append(textNode);
              textNode.select();
            }
          });
        }
      };

      onEditorReady(api);
    }
  }, [editor, onEditorReady]);

  return null;
}
